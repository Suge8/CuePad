import CloudKit
import Foundation

///
/// 连着时账号变了不能当作没事：此刻可能已是另一个账号，本机数据会传进去。所以通知一到就关上闸门（`AccountGate`）不拉不传，
/// 认清了才放开或停下等你决定；认不清的界面显示账号暂不可用，按退避再认。
/// 每一次认都从闸门领凭据：认的途中账号又变了就另起一次，旧的那次取消，它晚到的答复不写协调器、不改连接（`AccountGate.Check`）。
extension CloudSync {
  enum Outcome {
    case confirmed, retry, accountChange, paused
  }

  enum Trigger {
    case networkReturned, activated
  }

  /// 连上了为 true。调用方被取消就当场返回 false，不等认账号的请求到时限。
  @discardableResult
  func connectNow() async -> Bool {
    while let run = running {
      if let checking = run.checking {
        guard (try? await run.generation.outcome(of: Task<Bool, any Error> { await checking.value })) != nil else { return false }
        continue
      }
      if connected { return true }
      switch run.account {
      case .waiting(.retry(let at, _)) where ContinuousClock.now >= at: startCheck(run.generation)
      case .waiting: return false
      case .idle, .checking: startCheck(run.generation)
      }
    }
    return false
  }

  /// 那一拉在本代后台起、不等：账号变化按到达先后处理，下一次不排在一拉（可能挂到请求超时）后面。
  func recheck(_ generation: SyncGeneration) {
    let wasConnected = connected
    guard let task = startCheck(generation), let cloud = running?.cloud else { return }
    spawn(generation) {
      guard await task.value else { return }
      await self.pullAfterRecheck(wasConnected: wasConnected, cloud, generation)
    }
  }

  private func pullAfterRecheck(wasConnected: Bool, _ cloud: any SyncCloud, _ generation: SyncGeneration) {
    guard !generation.isOver, let puller = parts?.puller else { return }
    if wasConnected { spawn(generation) { await self.ensureAlertSubscriptions(cloud, generation) } }
    spawn(generation) { _ = try? await puller.pull() }
  }

  /// 回到前台（App 的唯一入口）：等着按退避再认的当场再认。iOS 上没登录、受限的，已连上的，与在认的也再认（连着的同账号变化一样先关闸门；
  /// 在认的那次可能是挂起前发出的，答复是挂起前的账号，作废另认）：
  /// App 被挂起期间换的账号，回来时不保证还收得到 `CKAccountChanged`（Apple 只说 App 在跑时用它察觉变化），连着的不认就会把挂起前没传出去的
  /// 传进新账号。代价是每次回前台两个认账号的请求、首拉晚一个来回。
  public func activated() {
    guard let generation = running?.generation else { return }
    recheckIfWaiting(generation, for: .activated)
  }

  /// Mac 不接回前台的那两种：App Nap 的文档只说压低 CPU 与定时器、没说挂起 App，由此推断账号变化的通知在跑着时照常送到（未经真机验证）；
  /// 而 Mac 每次切回 App 都算激活，接了就是每次切换都关一次闸门、多两个请求。
  #if os(iOS)
  static let missesAccountChangesWhileInBackground = true
  #else
  static let missesAccountChangesWhileInBackground = false
  #endif

  func recheckIfWaiting(_ generation: SyncGeneration, for trigger: Trigger) {
    guard let run = running, run.generation === generation else { return }
    switch (run.account, trigger) {
    case (.waiting(.retry), _): recheck(generation)
    case (.waiting(.accountChange), .activated), (.idle, .activated), (.checking, .activated):
      if Self.missesAccountChangesWhileInBackground { recheck(generation) }
    case (.waiting(.accountChange), .networkReturned), (.waiting(.paused), _), (.idle, .networkReturned), (.checking, .networkReturned): break
    }
  }

  /// 那一代已经结束的不起。
  @discardableResult
  func startCheck(_ generation: SyncGeneration) -> Task<Bool, Never>? {
    update(generation) { run in
      switch run.account {
      case .checking(let task): task.cancel()
      case .waiting(.retry(_, let timer)): timer.cancel()
      case .idle, .waiting: break
      }
      let check = run.gate.begin(closing: run.isConnected), cloud = run.cloud
      let task = Task { await self.checkAccount(check, cloud, generation) }
      run.account = .checking(task)
      return task
    }
  }

  func isLatest(_ check: AccountGate.Check) -> Bool { running?.gate.admits(check) == true }

  /// 返回是否认清、能接着拉；拉取由调用方接着发起（`syncNow`、`recheck`）。每个 await 之后先看自己还是不是最新的一次。
  func checkAccount(_ check: AccountGate.Check, _ cloud: any SyncCloud, _ generation: SyncGeneration) async -> Bool {
    do {
      let status = try await withDeadline(RequestLimits.request) { try await cloud.accountStatus() }
      await coordinator.accountStatus(status, from: check)
      switch status {
      case .available: break
      case .noAccount, .restricted: return await conclude(check, generation, .accountChange)
      default: return await conclude(check, generation, .retry)
      }
      let name = try await withDeadline(RequestLimits.request) { try await cloud.accountName() }
      await coordinator.account(name, from: check)
    } catch {
      guard isLatest(check) else { return false }
      if running?.backoff.isFresh == true { Self.log.notice("认 iCloud 账号失败，按退避再认：\(error.brief, privacy: .public)") }
      if !connected { await coordinator.accountFailed(error, from: check) }
      return await conclude(check, generation, .retry)
    }
    guard isLatest(check) else { return false }
    guard await !coordinator.stopped else { return await conclude(check, generation, .paused) }
    if connected { return await conclude(check, generation, .confirmed) }
    guard isLatest(check) else { return false }
    let parts = makeParts(cloud, generation)
    update(generation) { $0.link = .connected(parts) }  // 先于下面的 await：其间停下的由 `stop` 停这些部件
    await conclude(check, generation, .confirmed)
    await parts.sender.start()
    guard !generation.isOver else { return false }
    spawn(generation) {  // 文件那一路（接上一个进程交给系统的上传、看哪些文件要取）：第一拉不等它
      await parts.fileFetcher.start()
      await parts.fileSender.start()
    }
    update(generation) { $0.alertsAttemptedAt = .now }  // 立即同步不另起一遍
    spawn(generation) { await self.ensureAlertSubscriptions(cloud, generation) }  // 第一拉不等订阅
    return true
  }

  @discardableResult
  private func conclude(_ check: AccountGate.Check, _ generation: SyncGeneration, _ outcome: Outcome) async -> Bool {
    let concluded = update(generation) { run -> Bool in
      guard run.gate.end(check, verdict: run.isConnected ? (outcome == .confirmed ? .open : .unconfirmed) : nil) else { return false }
      switch outcome {
      case .confirmed, .paused:
        if !run.backoff.isFresh { Self.log.notice("认好 iCloud 账号") }
        run.backoff.reset()
        run.account = outcome == .confirmed ? .idle : .waiting(.paused)
      case .accountChange:
        run.account = .waiting(.accountChange)
      case .retry:
        let at = ContinuousClock.now + run.backoff.next()
        let timer = Task {
          try? await Task.sleep(until: at, clock: .continuous)
          guard !Task.isCancelled else { return }
          self.recheck(generation)
        }
        run.account = .waiting(.retry(at: at, timer))
      }
      return true
    }
    guard concluded == true else { return false }
    accountChecks.yield(())
    await coordinator.gateChanged()
    return outcome == .confirmed
  }

  /// 门铃的密钥（`RelaySecret`）：认过账号、能同步时才去 iCloud 取；没登录、要你决定时一直等到账号认好，不发请求。被取消、或同步停下了就抛出。
  public func relaySecret() async throws -> Data {
    let checks = accountChecks.stream()  // 先订阅：看条件时跨了 actor，其间认完的那一次不漏
    if !stopped, await !accountUsable() {
      for await _ in checks {
        if stopped { break }  // `stop` 给一个，让在等的醒来
        if await accountUsable() { break }
      }
    }
    try Task.checkCancellation()
    guard let cloud = running?.cloud else { throw CancellationError() }
    guard await coordinator.admits(.pull) else { throw RetryHeld() }  // 被限流时不另发请求：门铃按自己的退避再来
    return try await cloud.relaySecret()
  }

  private func accountUsable() async -> Bool { connected ? await coordinator.canSync : false }

  func ensureAlertSubscriptions(_ cloud: any SyncCloud, _ generation: SyncGeneration) async {
    guard Self.subscribesToAlerts, !generation.isOver else { return }
    update(generation) { $0.alertsAttemptedAt = .now }
    let status = await AlertSubscriptions(zoneID: Self.zoneID).ensure(in: cloud)
    guard !generation.isOver else { return }
    await coordinator.setAlerts(status)
  }
}

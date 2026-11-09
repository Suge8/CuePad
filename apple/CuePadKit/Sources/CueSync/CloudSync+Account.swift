import CloudKit
import Foundation

/// 认账号与等账号：`CloudSync` 的一代里，认账号、按原因再认、门铃的密钥。进度只在 `Run.account`（见 `Account`、`Wait`）。
///
/// 连着时账号变了不能当作没事：此刻可能已是另一个账号，本机数据会传进去。所以通知一到就关上闸门（`AccountGate`）不拉不传，
/// 认清了才放开或停下等你决定；认不清的界面显示账号暂不可用，按退避再认。
/// 每一次认都有序号：认的途中账号又变了就另起一次，旧的那次取消，它晚到的答复不写协调器、不改连接（`isLatest`）。
extension CloudSync {
  enum Outcome {
    case confirmed, retry, accountChange, paused
  }

  enum Trigger {
    case networkReturned, activated
  }

  /// 本代还没认过的先认，认的途中的等那一次（被更新的一次取代了就接着等新的）；等再认的不另认（`Wait`）。连上了为 true。
  /// 调用方被取消就当场返回 false，不等认账号的请求到时限。
  @discardableResult
  func connectNow() async -> Bool {
    while let run = running {
      if connected { return true }
      switch run.account {
      case .checking(_, let task):
        guard (try? await run.generation.outcome(of: Task<Bool, any Error> { await task.value })) != nil else { return false }
      case .waiting(.retry(let at, _)) where ContinuousClock.now >= at:
        startCheck(run.generation)
      case .waiting:
        return false
      case .idle:
        startCheck(run.generation)
      }
    }
    return false
  }

  /// 账号可能变了（`CKAccountChanged`、退避到点、网络回来、回到前台）：另起一次认，认好了在新账号的数据库里建订阅（连着的那里还没有），再拉一次。
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

  /// 回到前台（App 的唯一入口）：在等再认的当场再认。没登录、受限的也认：挂起期间换的账号，回来时不保证还收得到 `CKAccountChanged`
  /// （Apple 只说 App 在跑时用它察觉变化）。
  public func activated() {
    guard let generation = running?.generation else { return }
    recheckIfWaiting(generation, for: .activated)
  }

  func recheckIfWaiting(_ generation: SyncGeneration, for trigger: Trigger) {
    guard let run = running, run.generation === generation, case .waiting(let wait) = run.account else { return }
    switch (wait, trigger) {
    case (.retry, _), (.accountChange, .activated): recheck(generation)
    case (.accountChange, .networkReturned), (.paused, _): break
    }
  }

  /// 起本代新的一次认：在认的那次取消、作废，等着的定时取消；连着的当场关上闸门（已是认不清的照旧显示）。那一代已经结束的不起。
  @discardableResult
  func startCheck(_ generation: SyncGeneration) -> Task<Bool, Never>? {
    update(generation) { run in
      switch run.account {
      case .checking(_, let task): task.cancel()
      case .waiting(.retry(_, let timer)): timer.cancel()
      case .idle, .waiting: break
      }
      run.checks += 1
      let seq = run.checks, cloud = run.cloud
      let task = Task { await self.checkAccount(seq, cloud, generation) }
      run.account = .checking(seq: seq, task)
      if case .connected = run.link, run.gate.current == .open { run.gate.set(.checking) }
      return task
    }
  }

  func isLatest(_ seq: Int, _ generation: SyncGeneration) -> Bool {
    guard let run = running, run.generation === generation, case .checking(let latest, _) = run.account else { return false }
    return latest == seq
  }

  /// 认一次账号：状态交给协调器，可用时再认是不是上次同步的那个账号（换了就停下来等你决定）。本代还没连上的，认清且没停着就建部件、开始上传、
  /// 在后台建订阅。返回是否认清、能接着拉；拉取由调用方接着发起（`syncNow`、`recheck`）。每个 await 之后先看自己还是不是最新的一次。
  func checkAccount(_ seq: Int, _ cloud: any SyncCloud, _ generation: SyncGeneration) async -> Bool {
    do {
      let status = try await withDeadline(RequestLimits.request) { try await cloud.accountStatus() }
      guard isLatest(seq, generation) else { return false }
      await coordinator.accountStatus(status)
      switch status {
      case .available: break
      case .noAccount, .restricted: return await conclude(seq, generation, .accountChange)
      // 暂不可用、无法确定，与认不出的新状态：界面说稍后自动重试（`SyncStatus.accountUnavailable`），就按退避再认
      default: return await conclude(seq, generation, .retry)
      }
      let name = try await withDeadline(RequestLimits.request) { try await cloud.accountName() }
      guard isLatest(seq, generation) else { return false }
      await coordinator.account(name)
    } catch {
      guard isLatest(seq, generation) else { return false }
      if running?.backoff.isFresh == true { Self.log.notice("认 iCloud 账号失败，按退避再认：\(error.brief, privacy: .public)") }
      if !connected {
        if SyncFault(error).isOffline {
          await coordinator.failed(error)  // 连不上的经协调器按段记（`SyncCoordinator.noteWaiting`）
        } else {
          await coordinator.accountStatus(.couldNotDetermine)
        }
      }
      return await conclude(seq, generation, .retry)
    }
    guard isLatest(seq, generation) else { return false }
    guard await !coordinator.stopped else { return await conclude(seq, generation, .paused) }
    if connected { return await conclude(seq, generation, .confirmed) }
    guard isLatest(seq, generation) else { return false }
    let parts = makeParts(cloud, generation)
    update(generation) { $0.link = .connected(parts) }  // 先于下面的 await：其间停下的由 `stop` 停这些部件
    await conclude(seq, generation, .confirmed)
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

  /// 最新的这一次认完：定下等什么再认、闸门开没开，告诉等账号认好的（`relaySecret`）。返回是否认清。
  @discardableResult
  private func conclude(_ seq: Int, _ generation: SyncGeneration, _ outcome: Outcome) async -> Bool {
    guard isLatest(seq, generation) else { return false }
    update(generation) { run in
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
      if case .connected = run.link { run.gate.set(outcome == .confirmed ? .open : .unconfirmed) }
    }
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

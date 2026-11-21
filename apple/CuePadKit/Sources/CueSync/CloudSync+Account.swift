import CloudKit
import Foundation

extension CloudSync {
  enum Outcome {
    case confirmed, retry, accountChange, paused
  }

  enum Trigger {
    case networkReturned, activated
  }

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
    update(generation) { $0.link = .connected(parts) }
    await conclude(check, generation, .confirmed)
    await parts.sender.start()
    guard !generation.isOver else { return false }
    spawn(generation) {
      await parts.fileFetcher.start()
      await parts.fileSender.start()
    }
    update(generation) { $0.alertsAttemptedAt = .now }
    spawn(generation) { await self.ensureAlertSubscriptions(cloud, generation) }
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

  public func relaySecret() async throws -> Data {
    try await usableCloud(for: .pull).relaySecret()
  }

  func usableCloud(for request: SyncCoordinator.Request) async throws -> any SyncCloud {
    let checks = accountChecks.stream()
    if !stopped, await !accountUsable() {
      for await _ in checks {
        if stopped { break }
        if await accountUsable() { break }
      }
    }
    try Task.checkCancellation()
    guard let cloud = running?.cloud else { throw CancellationError() }
    guard await coordinator.admits(request) else { throw RetryHeld() }
    return cloud
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

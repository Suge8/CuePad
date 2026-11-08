import CloudKit
import Foundation

/// 认账号与等账号：`CloudSync` 的一代里，认账号、按退避再认、账号变化与门铃的密钥。
///
/// 连着时认不清（账号变了之后取不到状态或账号名、暂不可用）不能当作没事：此刻可能已是另一个账号，本机数据会传进去。
/// 交给协调器挡住拉传（`SyncCoordinator.accountUnconfirmed`，界面显示账号暂不可用），按退避再认，认清了才放开或停下等你决定。
extension CloudSync {
  /// 认账号：状态交给协调器，可用时再认是不是上次同步的那个账号（换了就停下来等你决定）。还没开始的，认过且能同步就开始上传、在后台建订阅；
  /// 已开始后的账号变化（退出、受限、换了账号）由协调器停下（`canSync`）。认不了、暂不可用的按退避再认（`accountBackoff`）；没登录的等账号变化。
  /// 返回是否认清、能接着拉。拉取由调用方接着发起（`syncNow`、账号变化）。每个 await 之后看这一代结束没有：停下或重启了的旧一代什么都不再改。
  @discardableResult
  func checkAccount(_ cloud: any SyncCloud, _ generation: SyncGeneration) async -> Bool {
    do {
      let status = try await withDeadline(RequestLimits.request) { try await cloud.accountStatus() }
      guard !generation.isOver else { return false }
      await coordinator.accountStatus(status)
      guard status == .available else {
        if [.temporarilyUnavailable, .couldNotDetermine].contains(status) {
          if connected { await coordinator.accountUnconfirmed() }
          retryAccount(generation)
        }
        return false
      }
      let name = try await withDeadline(RequestLimits.request) { try await cloud.accountName() }
      guard !generation.isOver else { return false }
      await coordinator.account(name)
    } catch {
      guard !generation.isOver else { return false }
      if accountRetryAt == nil { Self.log.notice("认 iCloud 账号失败，按退避再认：\(error.brief, privacy: .public)") }
      if connected {
        await coordinator.accountUnconfirmed()  // 连着时认不清：认清之前不拉不传（见类型注释）
      } else if SyncFault(error).isOffline {
        await coordinator.failed(error)  // 连不上的经协调器按段记（`SyncCoordinator.noteWaiting`）
      } else {
        await coordinator.accountStatus(.couldNotDetermine)
      }
      retryAccount(generation)
      return false
    }
    guard !generation.isOver else { return false }
    accountRetry?.cancel()
    accountRetry = nil
    if accountRetryAt != nil { Self.log.notice("认好 iCloud 账号") }
    accountRetryAt = nil
    accountBackoff.reset()
    defer { accountChecks.yield(()) }
    guard !connected else { return true }
    guard await coordinator.canSync, !generation.isOver, let sender, let fileSender, let fileFetcher else { return false }
    connected = true
    await sender.start()
    spawn {  // 文件那一路（接上一个进程交给系统的上传、看哪些文件要取）：第一拉不等它
      await fileFetcher.start()
      await fileSender.start()
    }
    alertsAttemptedAt = .now  // 立即同步不另起一遍
    spawn { await self.ensureAlertSubscriptions(cloud, generation) }  // 第一拉不等订阅
    return true
  }

  /// 按退避再认一次（连着的也再认：`accountChanged`）。到点后先把自己从登记里摘掉：认好时不取消正在认的这一次。
  func retryAccount(_ generation: SyncGeneration) {
    let at = ContinuousClock.now + accountBackoff.next()
    accountRetryAt = at
    accountRetry?.cancel()
    accountRetry = Task {
      try? await Task.sleep(until: at, clock: .continuous)
      guard !Task.isCancelled, !generation.isOver else { return }
      accountRetry = nil
      await accountChanged()  // 拉取失败由协调器归类、按段记（`SyncCoordinator.noteWaiting`）
    }
  }

  /// 账号变了（或到点再认）：再认一次（换了账号就停下等你决定）；能同步的在新账号的数据库里建订阅（里面还没有），再拉一次。
  /// 那一拉在本代后台起、不等：账号变化按到达先后处理，下一次不排在一拉（可能挂到请求超时）后面。
  func accountChanged() async {
    guard case .running(let generation) = phase, let cloud else { return }
    let wasConnected = connected
    accountRetryAt = nil  // 账号变了是新情况，不等上次失败的退避
    guard wasConnected ? await checkAccount(cloud, generation) : await connectNow() else { return }
    guard !generation.isOver, let puller else { return }
    if wasConnected { spawn { await self.ensureAlertSubscriptions(cloud, generation) } }  // 刚开始的已在建
    spawn { _ = try? await puller.pull() }
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
    guard case .running = phase, let cloud else { throw CancellationError() }
    guard await coordinator.admits(.pull) else { throw RetryHeld() }  // 被限流时不另发请求：门铃按自己的退避再来
    return try await cloud.relaySecret()
  }

  private func accountUsable() async -> Bool { connected ? await coordinator.canSync : false }

  func ensureAlertSubscriptions(_ cloud: any SyncCloud, _ generation: SyncGeneration) async {
    guard Self.subscribesToAlerts, !generation.isOver else { return }
    alertsAttemptedAt = .now
    let status = await AlertSubscriptions(zoneID: Self.zoneID).ensure(in: cloud)
    guard !generation.isOver else { return }
    await coordinator.setAlerts(status)
  }
}

import Foundation

/// 唯一的重试调度：上传（`RecordSender`）、拉取（`ZonePuller`）与文件那一路（`FileSender`、`FileFetcher`）失败后，协调器归类（`SyncFault`），由这里定下次最早什么时候再发。
/// 连不上与没给时刻的等待按退避（`Backoff`，有人在等时上限小），服务器给的时刻照它（限流按设备算，正式版与别的进程共用一份，不守只会被限得更久），
/// 账号按长退避，整个上传被拒停 `rejectedPause`。门铃、立即同步、按节奏的拉取与发送者的每一轮都守同一个时刻（`admits`）；
/// 到点或提前结束时给 `retryDue`，发送者接着发、拉取器补上被挡下的那一拉。
/// 连不上时拉取只守服务器给的时刻、不守退避：连不上的请求到不了服务器，不加重限流；拉取又是别的设备的改动到这台的唯一通路，
/// 网络路径没变的恢复（只是 iCloud 连不上）没有别的证据，按退避拉要多等一个退避（模拟云断网 30 秒实测恢复→第一次成功 p50 0.85 → 6.5 秒）。
/// 连通的证据（任何一次请求成功、网络路径恢复）提前结束连不上的等待，服务器给的时刻照守；有一批收下只结束退避（`progressed`）。
/// 只有 iCloud 空间不足是文件那一路自己的：文件停 `quotaPause`（`holdFiles`），别的记录照常同步，所以不进 `status`（`SyncState.filesOverQuota`）。
extension SyncCoordinator {
  struct Hold {
    var until: ContinuousClock.Instant
    var fault: SyncFault
    /// 服务器给的最早时刻：连通的证据与收下一批都不提前它。
    var notBefore: ContinuousClock.Instant
  }

  enum Request {
    /// 上传：`urgent` 是用户在等的一轮（马上传、进后台前），越过连不上与整个请求被拒的等待。
    case upload(urgent: Bool)
    /// 拉取：守服务器要求的等待；连不上只守服务器给的时刻（见类型注释），上传被拒、账号在等的不挡拉取。
    case pull
    /// 传一个文件：同后台那一路的上传，另守空间不足的停顿。
    case fileUpload
    /// 取一个文件：同上传；用到时取的（`urgent`）同马上传，越过连不上与被拒的等待。
    case fileDownload(urgent: Bool)

    /// 用户在等：越过连不上与被拒的等待。
    var urgent: Bool {
      switch self {
      case .upload(let urgent), .fileDownload(let urgent): urgent
      case .pull, .fileUpload: false
      }
    }
  }

  static let rejectedPause = Duration.seconds(60)
  static let quotaPause = Duration.seconds(600)

  /// 此刻能不能发这种请求。服务器给的最早时刻谁都守。
  func admits(_ request: Request) -> Bool {
    let now = ContinuousClock.now
    if case .fileUpload = request, let until = facts.filesHeldUntil, now < until { return false }
    guard let hold = holding, now < hold.until else { return true }
    guard now >= hold.notBefore else { return false }
    return switch (request, hold.fault) {
    case (.pull, .wait): false
    case (.pull, _): true
    case (_, .offline), (_, .rejected): request.urgent
    case (_, .wait), (_, .account): false
    }
  }

  /// 一次失败定下次最早什么时候发。`waiting`：有人在等结果（马上传了还没收下），没给时刻的等待也压到 `Backoff.waitingCap`。
  /// 两路的结果先后回来，后到的不缩短先前服务器给的时刻。
  func hold(_ fault: SyncFault, waiting: Bool) {
    let now = ContinuousClock.now
    let cap = waiting ? Backoff.waitingCap : nil
    let notBefore = max(now + (fault.retryAfter ?? .zero), holding?.notBefore ?? now)
    let until: ContinuousClock.Instant =
      switch fault {
      case .offline: now + backoff.next(cap: cap)
      case .wait(let given): given.map { now + $0 } ?? now + backoff.next(cap: cap)
      case .account: now + backoff.next()
      case .rejected: now + Self.rejectedPause
      }
    setHold(Hold(until: max(until, notBefore), fault: fault, notBefore: notBefore))
  }

  /// iCloud 空间不足（文件被拒）：文件那一路停 `quotaPause`，到点给 `retryDue` 再试；别的记录照常。
  func holdFiles(_ error: any Error) {
    if facts.filesHeldUntil == nil { Self.syncLog.notice("iCloud 空间不足，文件先不上传：\(error.brief, privacy: .public)") }
    let until = ContinuousClock.now + Self.quotaPause
    facts.filesHeldUntil = until
    quotaTimer?.cancel()
    quotaTimer = Task {
      try? await Task.sleep(until: until, clock: .continuous)
      guard !Task.isCancelled else { return }
      self.retryDue.yield(())
    }
  }

  /// 服务器收下了一个文件：空间够了。
  func filesAccepted() {
    guard facts.filesHeldUntil != nil else { return }
    facts.filesHeldUntil = nil
    quotaTimer?.cancel()
    quotaTimer = nil
  }

  /// 有一批收下了：退避到此为止，服务器给的最早时刻照守（另一路被限流时它还在）。
  func progressed() {
    backoff.reset()
    guard let hold = holding, ContinuousClock.now < hold.notBefore else { return release() }
    setHold(Hold(until: hold.notBefore, fault: hold.fault, notBefore: hold.notBefore))
  }

  /// 连通的证据（`succeeded`、网络路径恢复）：因连不上在等的不再等退避，服务器给的最早时刻照守。
  func connected() {
    guard let hold = holding, hold.fault.isOffline else { return }
    guard ContinuousClock.now >= hold.notBefore else { return setHold(Hold(until: hold.notBefore, fault: hold.fault, notBefore: hold.notBefore)) }
    release()
  }

  /// 会自己恢复的失败（连不上、服务器要求等、账号）按段记日志：进入时一条（归类、等多久、原因原话），恢复时一条（`noteRecovered`），
  /// 其间每次重试不记；换了一类算新的一段。意料之外的（`rejected`）进问题列表时记 error（`report`）。
  func noteWaiting(_ fault: SyncFault, _ error: any Error) {
    guard fault != .rejected, !stopped else { return }
    if let outage, outage.fault.sameKind(as: fault) { return }
    outage = (fault, .now)
    let wait = fault.retryAfter.map { "服务器要求 \(String(format: "%.1f", $0.seconds)) 秒后再试" }
      ?? "下一次触发或退避到点再试"
    Self.syncLog.notice("同步进入等待：\(fault.label, privacy: .public)，\(wait, privacy: .public)。原因：\(error.brief, privacy: .public)")
  }

  /// 一次请求成功：在等的那一段结束。
  func noteRecovered() {
    guard let outage else { return }
    self.outage = nil
    let lasted = (ContinuousClock.now - outage.began).seconds
    Self.syncLog.notice("同步恢复：\(outage.fault.label, privacy: .public)，持续了 \(lasted, format: .fixed(precision: 1), privacy: .public) 秒")
  }

  private func setHold(_ next: Hold) {
    holding = next
    facts.serverWait = next.fault.isWait
    retryTimer?.cancel()
    retryTimer = Task { [until = next.until] in
      try? await Task.sleep(until: until, clock: .continuous)
      guard !Task.isCancelled else { return }
      self.release()
    }
  }

  /// 等待结束（到点或提前）：在等的接着发、被挡下的那一拉补上。
  private func release() {
    guard holding != nil else { return }
    holding = nil
    facts.serverWait = false
    retryTimer?.cancel()
    retryTimer = nil
    retryDue.yield(())
  }
}

/// 重试调度要求等着（`SyncCoordinator.admits`）：拉取途中停下记成欠着（`ZonePuller`），取门铃密钥的这次不发（`CloudSync.relaySecret`）。不算失败。
struct RetryHeld: LocalizedError {
  var errorDescription: String? { "同步在等重试的时刻" }
}

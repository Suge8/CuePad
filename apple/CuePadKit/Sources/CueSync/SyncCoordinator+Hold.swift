import Foundation

/// 唯一的重试调度：上传、拉取与文件那一路失败后，协调器归类（`SyncFault`），由这里定下次最早什么时候再发；各路都守同一个时刻（`admits`），到点或提前结束时给 `retryDue`。
/// 服务器给的时刻照它（限流按设备算，正式版与别的进程共用一份，不守只会被限得更久）。
/// 连不上时拉取只守服务器给的时刻、不守退避：连不上的请求到不了服务器，不加重限流；拉取又是别的设备的改动到这台的唯一通路，
/// 网络路径没变的恢复（只是 iCloud 连不上）没有别的证据，按退避拉要多等一个退避（模拟云断网 30 秒实测恢复→第一次成功 p50 0.85 → 6.5 秒）。
extension SyncCoordinator {
  struct Hold {
    var until: ContinuousClock.Instant
    var fault: SyncFault
    /// 服务器给的最早时刻：连通的证据与收下一批都不提前它。
    var notBefore: ContinuousClock.Instant
    /// 在等服务器要求的时刻（限流、区忙，或后来的失败盖过了它、它还没到）：界面显示同步中（`Facts.state`）。
    let server: Bool

    init(until: ContinuousClock.Instant, fault: SyncFault, notBefore: ContinuousClock.Instant) {
      (self.until, self.fault, self.notBefore) = (until, fault, notBefore)
      server = fault.isWait || notBefore > .now
    }
  }

  enum Request {
    case upload(urgent: Bool)
    case pull
    case fileUpload
    case fileDownload(urgent: Bool)

    var urgent: Bool {
      switch self {
      case .upload(let urgent), .fileDownload(let urgent): urgent
      case .pull, .fileUpload: false
      }
    }
  }

  static let rejectedPause = Duration.seconds(60)
  static let quotaPause = Duration.seconds(600)

  func admits(_ request: Request) -> Bool {
    let now = ContinuousClock.now
    if case .fileUpload = request, let until = facts.filesHeldUntil, now < until { return false }
    guard let hold = facts.holding, now < hold.until else { return true }
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
    let notBefore = max(now + (fault.retryAfter ?? .zero), facts.holding?.notBefore ?? now)
    let until: ContinuousClock.Instant =
      switch fault {
      case .offline: now + backoff.next(cap: cap)
      case .wait(let given): given.map { now + $0 } ?? now + backoff.next(cap: cap)
      case .account: now + backoff.next()
      case .rejected: now + Self.rejectedPause
      }
    setHold(Hold(until: max(until, notBefore), fault: fault, notBefore: notBefore))
  }

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

  func filesAccepted() {
    guard facts.filesHeldUntil != nil else { return }
    facts.filesHeldUntil = nil
    quotaTimer?.cancel()
    quotaTimer = nil
  }

  /// 服务器给的最早时刻照守：另一路被限流时它还在。
  func progressed() {
    backoff.reset()
    guard let hold = facts.holding, ContinuousClock.now < hold.notBefore else { return release() }
    setHold(Hold(until: hold.notBefore, fault: hold.fault, notBefore: hold.notBefore))
  }

  func connected() {
    guard let hold = facts.holding, hold.fault.isOffline else { return }
    guard ContinuousClock.now >= hold.notBefore else { return setHold(Hold(until: hold.notBefore, fault: hold.fault, notBefore: hold.notBefore)) }
    release()
  }

  func noteWaiting(_ fault: SyncFault, _ error: any Error) {
    guard fault != .rejected, !stopped else { return }
    if let outage, outage.fault.sameKind(as: fault) { return }
    outage = (fault, .now)
    let wait = fault.retryAfter.map { "服务器要求 \(String(format: "%.1f", $0.seconds)) 秒后再试" }
      ?? "下一次触发或退避到点再试"
    Self.syncLog.notice("同步进入等待：\(fault.label, privacy: .public)，\(wait, privacy: .public)。原因：\(error.brief, privacy: .public)")
  }

  func noteRecovered() {
    guard let outage else { return }
    self.outage = nil
    let lasted = (ContinuousClock.now - outage.began).seconds
    Self.syncLog.notice("同步恢复：\(outage.fault.label, privacy: .public)，持续了 \(lasted, format: .fixed(precision: 1), privacy: .public) 秒")
  }

  private func setHold(_ next: Hold) {
    facts.holding = next
    retryTimer?.cancel()
    retryTimer = Task { [until = next.until] in
      try? await Task.sleep(until: until, clock: .continuous)
      guard !Task.isCancelled else { return }
      self.release()
    }
  }

  private func release() {
    guard facts.holding != nil else { return }
    facts.holding = nil
    retryTimer?.cancel()
    retryTimer = nil
    retryDue.yield(())
  }

  /// 在等的照样给一次 `retryDue`，新一代当场发。
  func clearHolds() {
    backoff.reset()
    outage = nil
    release()
    facts.filesHeldUntil = nil
    quotaTimer?.cancel()
    quotaTimer = nil
  }
}

/// 重试调度要求等着，不算失败。
struct RetryHeld: LocalizedError {
  var errorDescription: String? { "同步在等重试的时刻" }
}

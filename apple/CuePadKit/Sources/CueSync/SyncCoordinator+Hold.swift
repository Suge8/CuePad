import Foundation

/// 唯一的重试调度：上传（`RecordSender`）与拉取（`ZonePuller`）失败后，协调器归类（`SyncFault`），由这里定下次最早什么时候再发。
/// 连不上与没给时刻的等待按退避（`Backoff`，有人在等时上限小），服务器给的时刻照它（限流按设备算，正式版与别的进程共用一份，不守只会被限得更久），
/// 账号按长退避，整个上传被拒停 `rejectedPause`。门铃、立即同步、按节奏的拉取与发送者的每一轮都守同一个时刻（`admits`）；
/// 到点或提前结束时给 `retryDue`，发送者接着发、拉取器补上被挡下的那一拉。
/// 连不上时拉取只守服务器给的时刻、不守退避：连不上的请求到不了服务器，不加重限流；拉取又是别的设备的改动到这台的唯一通路，
/// 网络路径没变的恢复（只是 iCloud 连不上）没有别的证据，按退避拉要多等一个退避（模拟云断网 30 秒实测恢复→第一次成功 p50 0.85 → 6.5 秒）。
/// 连通的证据（任何一次请求成功、网络路径恢复）提前结束连不上的等待，服务器给的时刻照守；有一批收下只结束退避（`progressed`）。
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
  }

  static let rejectedPause = Duration.seconds(60)

  /// 此刻能不能发这种请求。服务器给的最早时刻谁都守。
  func admits(_ request: Request) -> Bool {
    let now = ContinuousClock.now
    guard let hold = holding, now < hold.until else { return true }
    guard now >= hold.notBefore else { return false }
    return switch (request, hold.fault) {
    case (.upload(let urgent), .offline), (.upload(let urgent), .rejected): urgent
    case (.upload, .wait), (.upload, .account): false
    case (.pull, .wait): false
    case (.pull, .offline), (.pull, .account), (.pull, .rejected): true
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

  private func setHold(_ next: Hold) {
    holding = next
    facts.serverWait = if case .wait = next.fault { true } else { false }
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

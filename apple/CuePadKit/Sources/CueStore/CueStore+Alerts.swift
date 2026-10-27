import Foundation

/// 一条提示说的是什么：一个会话的"等你"、"待回复"或"做完了"（会话记录 id，`PiSessionState.id`；锁屏通知只带它），或 Cue 的一条消息。
public enum AlertSubject: Hashable, Sendable {
  case session(UUID, PiAlert)
  case cue
}

/// 会话记录怎么推到手机（`PiSessionState.notify` 的值，明文、可查询，服务端订阅各按一种值推，见 `AlertSubscriptions`）：
/// 到得了你的出那种提示的可见通知（同时叫醒 App 拉一次）；该你接、你却正在 Mac 上开着它的只静默叫醒 App 拉一次，灵动岛与小组件照样跟上——
/// 同 Cue 的消息（`CuePush`）：一件事进了等你，手机总会被叫醒，到不到你只定出不出通知。
public enum PiPush: Hashable, Sendable {
  case alert(PiAlert)
  case wake

  static let wakeValue = "wake"

  public init?(rawValue: String) {
    if rawValue == Self.wakeValue { self = .wake } else if let alert = PiAlert(rawValue: rawValue) { self = .alert(alert) } else { return nil }
  }

  public var rawValue: String {
    switch self {
    case .alert(let alert): alert.rawValue
    case .wake: Self.wakeValue
    }
  }
}

extension CueStore {
  /// 这条提示此刻到不到你：Cue 消息的推送标志（`insertCueMessage`）、Mac 的通知与手机前台的会话横幅（`AlertCenter`、`SessionAlertTracker` 认出候选之后）
  /// 都只问这里，会话的推送标志问同一条规则的 `push`。会话记录已不在为不到。
  public func reaches(_ subject: AlertSubject) throws -> Bool {
    switch subject {
    case .cue: try !watchedOnMac(\.cue)
    case .session(let id, let alert): try find(PiSessionState.self, id).map { try push(alert, $0) == .alert(alert) } ?? false
    }
  }

  /// 会话的这次提示怎么推（`PiPush`），两半：
  /// - 这一停该你接：等你确认要真在等你（`PiSessionState.asksYou`）；待回复要还待回复（`awaitsReply`）；做完了只在 Cue 不值班时算——
  ///   值班时留给你回的（你发起的一轮当场就是）另按待回复提示（`flagLeftToYou`），其余归 Cue 接。不该你接的不推。
  /// - 你没在看：没在哪台在线的 Mac 上开着这个会话页（`watchedOnMac`）就出通知，开着就只叫醒。
  func push(_ alert: PiAlert, _ state: PiSessionState) throws -> PiPush? {
    let cue = try cueDuty()
    let yours = switch alert {
    case .waitingForUser: state.asksYou(cue)
    case .awaitsReply: state.awaitsReply(cue)
    case .settled: cue == nil
    }
    guard yours else { return nil }
    return try watchedOnMac { $0.sessionID.map(PiSessionState.recordID) == state.id } ? .wake : .alert(alert)
  }

  /// 这次停下刚留给你（`CueLeft`，会话状态没变，状态转换的标志轮不到它）：会话在这台 Mac 上（会话记录只有它写）、
  /// 这次停下还在，就给会话记录置手机推送标志（哪种提示见 `PiSessionState.leftAlert`，怎么推见 `push`）。
  /// 返回记录 id（立即上传用），没置为 nil。
  @discardableResult
  public func flagLeftToYou(_ left: CueLeft, host: String) throws -> UUID? {
    try write {
      guard let state = try sessionState(left.sessionID), state.hostID == host, left.holds(for: state),
        let push = try push(state.leftAlert, state)
      else { return nil }
      try db.run(
        "UPDATE piSessionStates SET notify = ?1, modifiedAt = ?2 WHERE id = ?3 AND notify IS NULL",
        [push.rawValue, Date.stamp, state.id])
      return db.changes > 0 ? state.id : nil
    }
  }
}

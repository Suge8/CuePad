import Foundation

public enum AlertSubject: Hashable, Sendable {
  case session(UUID, PiAlert)
  case cue
}

/// 到得了你的出那种提示的可见通知（同时叫醒 App 拉一次）；该你接、你却正在 Mac 上开着它的只静默叫醒 App 拉一次，灵动岛与小组件照样跟上：一件事进了等你，手机总会被叫醒，到不到你只定出不出通知。
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
  /// Cue 消息的推送标志、Mac 的通知与手机前台的会话横幅都只问这里，会话的推送标志问同一条规则的 `push`。会话记录已不在为不到。
  public func reaches(_ subject: AlertSubject) throws -> Bool {
    switch subject {
    case .cue: try !watchedOnMac(\.cue)
    case .session(let id, let alert): try find(PiSessionState.self, id).map { try push(alert, $0) == .alert(alert) } ?? false
    }
  }

  /// 不该你接的不推；你没在看（没在哪台在线的 Mac 上开着这个会话页）才出通知，开着就只叫醒。做完了只在 Cue 不值班时算；值班时留给你回的另按待回复提示（`flagLeftToYou`），其余归 Cue 接。
  func push(_ alert: PiAlert, _ state: PiSessionState) throws -> PiPush? {
    let cue = try cueDuty()
    let yours = switch alert {
    case .waitingForUser: state.asksYou(cue)
    case .awaitsReply: state.awaitsReply(cue)
    case .settled: cue == nil
    }
    guard yours else { return nil }
    return try watchedOnMac { $0.sessionIDs.contains(state.sessionID) } ? .wake : .alert(alert)
  }

  /// 这次停下刚留给你（`CueLeft`，会话状态没变，状态转换的标志轮不到它）：会话在这台 Mac 上（会话记录只有它写）、这次停下还在，就置手机推送标志。返回记录 id（立即上传用）。
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

import Foundation

public enum AlertSubject: Hashable, Sendable {
  case session(UUID, AlertKind)
  case cue
}

public enum AlertPush: Hashable, Sendable {
  case alert(AlertKind)
  case wake

  static let wakeValue = "wake"

  public init?(rawValue: String) {
    if rawValue == Self.wakeValue { self = .wake } else if let alert = AlertKind(rawValue: rawValue) { self = .alert(alert) } else { return nil }
  }

  public var rawValue: String {
    switch self {
    case .alert(let alert): alert.rawValue
    case .wake: Self.wakeValue
    }
  }
}

extension CueStore {
  public func reaches(_ subject: AlertSubject) throws -> Bool {
    switch subject {
    case .cue: try !watchedOnMac(\.cue)
    case .session(let id, let alert): try find(SessionState.self, id).map { try push(alert, $0) == .alert(alert) } ?? false
    }
  }

  func push(_ alert: AlertKind, _ state: SessionState) throws -> AlertPush? {
    let cue = try cueDuty()
    let yours = switch alert {
    case .waitingForUser: try state.asksYou(cue) && !notEnding([state]).isEmpty
    case .awaitsReply: try state.awaitsReply(cue) && !notEnding([state]).isEmpty
    case .settled: cue == nil
    }
    guard yours else { return nil }
    return try watchedOnMac { $0.sessionIDs.contains(state.sessionID) } ? .wake : .alert(alert)
  }

  @discardableResult
  public func flagLeftToYou(_ left: CueLeft, host: String) throws -> UUID? {
    try write {
      guard var state = try sessionState(left.sessionID), state.hostID == host, left.holds(for: state) else { return nil }
      state.runtimeUntil = Date.stamp
      guard let push = try push(state.leftAlert, state) else { return nil }
      try db.run(
        "UPDATE piSessionStates SET notify = ?1, modifiedAt = ?2 WHERE id = ?3 AND notify IS NULL",
        [push.rawValue, Date.stamp, state.id])
      return db.changes > 0 ? state.id : nil
    }
  }
}

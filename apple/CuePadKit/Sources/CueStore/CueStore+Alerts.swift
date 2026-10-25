import Foundation

/// 一条提示说的是什么：一个会话的"等你"、"待回复"或"做完了"（会话记录 id，`PiSessionState.id`；锁屏通知只带它），或 Cue 的一条消息。
public enum AlertSubject: Hashable, Sendable {
  case session(UUID, PiAlert)
  case cue
}

extension CueStore {
  /// 这条提示此刻到不到你：手机推送标志（`PiStateRecorder`、`flagLeftToYou`、`insertCueMessage`）、Mac 的通知与手机前台的会话横幅
  /// （`AlertCenter`、`SessionAlertTracker` 认出候选之后）都只问这里。会话记录已不在为不到。
  public func reaches(_ subject: AlertSubject) throws -> Bool {
    switch subject {
    case .cue: try !watchedOnMac(\.cue)
    case .session(let id, let alert): try find(PiSessionState.self, id).map { try reaches(alert, $0) } ?? false
    }
  }

  /// 会话的提示到不到你，两半都要成立：
  /// - 这一停该你接：等你确认要真在等你（`PiSessionState.asksYou`）；待回复要还待回复（`awaitsReply`）；做完了在 Cue 不值班时都算，
  ///   值班时会话归它接手，只有归你的停下（`hisStop`：你发起的一轮、你在场）才算——它留给你回的另按待回复提示（`flagLeftToYou`）。
  /// - 你没在看：没在哪台在线的 Mac 上开着这个会话页（`watchedOnMac`）。
  func reaches(_ alert: PiAlert, _ state: PiSessionState) throws -> Bool {
    let cue = try cueDuty()
    let yours = switch alert {
    case .waitingForUser: state.asksYou(cue)
    case .awaitsReply: state.awaitsReply(cue)
    case .settled: try cue.map { _ in try hisStop(state.sessionID) != nil } ?? true
    }
    return try yours && !watchedOnMac { $0.sessionID.map(PiSessionState.recordID) == state.id }
  }

  /// Cue 刚把这次停下留给你（`leaveToYou`，会话状态没变，状态转换的标志轮不到它）：会话在这台 Mac 上（会话记录只有它写）、
  /// 这次停下还在、到得了你，就给会话记录置手机推送标志——歇着的是待回复，在等回答的是等你确认（它本来就在问你，留给你只是 Cue 不替你答）。
  /// 返回记录 id（立即上传用），没置为 nil。
  @discardableResult
  public func flagLeftToYou(_ left: CueLeft, host: String) throws -> UUID? {
    try write {
      guard let state = try sessionState(left.sessionID), state.hostID == host, left.holds(for: state) else { return nil }
      let alert: PiAlert = state.state == .known(.settled) ? .awaitsReply : .waitingForUser
      guard try reaches(alert, state) else { return nil }
      try db.run(
        "UPDATE piSessionStates SET notify = ?1, modifiedAt = ?2 WHERE id = ?3 AND notify IS NULL",
        [alert.rawValue, Date.stamp, state.id])
      return db.changes > 0 ? state.id : nil
    }
  }
}

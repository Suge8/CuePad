import Foundation

extension CueStore {
  /// 做完了、结果你还没看的那件（Cue 页舞台上的一行）：交给过 Agent、7 天内做完，它的会话停下后你还没看过（`SessionState.isUnread`）；
  /// 最近做完的那件。看结果就是看那个会话，所以不另记"看过"：从哪里打开它的会话都算。
  public func unseenDone() throws -> Card? {
    let now = timing.now(), window: TimeInterval = 7 * 86_400
    let done = try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t
      WHERE \(Self.taskOnBoard("t")) AND t.completedAt >= ? AND t.piSessionID IS NOT NULL
      ORDER BY \(Self.recentlyDone)
      """, [now.addingTimeInterval(-window)]
    ) { Card(row: $0) }
    for task in done {
      guard let completed = task.completedAt, let session = task.piSessionID, let state = try sessionState(session) else { continue }
      expire(at: completed.addingTimeInterval(window))
      let marks = try sessionMarks(session)
      if state.isUnread(marks, at: now) {
        expire(at: state.unreadUntil(marks))
        return task
      }
    }
    return nil
  }
}

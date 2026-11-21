import Foundation

extension CueStore {
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

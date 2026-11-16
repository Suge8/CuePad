import Foundation

extension CueStore {
  /// 舞台上请你点头的灵感（Cue 页的建议）：散放、没归档、不空、14 天内建的，今天没划掉的（`Mark.ideaSkipped`）；新的在前。到点（出了 14 天、过了今天）重读。
  public func pendingIdeas(limit: Int) throws -> [Card] {
    let now = timing.now(), window: TimeInterval = 14 * 86_400
    let today = Calendar.current.startOfDay(for: now)
    let ideas = try select(
      Card.self,
      where: """
        (\(Self.cardActive)) AND (\(Self.looseIdea)) AND \(Self.notBlank) AND createdAt >= ?
          AND id NOT IN (SELECT subject FROM marks WHERE kind = 'ideaSkipped' AND modifiedAt >= ?)
        """,
      [now.addingTimeInterval(-window), today], orderBy: "createdAt DESC, id", limit: limit)
    if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) { expire(at: tomorrow) }
    for idea in ideas { expire(at: idea.createdAt.addingTimeInterval(window)) }
    return ideas
  }

  /// 做完了、结果你还没看的那件（舞台上"做完"那一件）：交给过 Agent、7 天内做完，它的会话停下后你还没看过（`SessionState.isUnread`）；
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

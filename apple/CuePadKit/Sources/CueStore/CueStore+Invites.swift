import Foundation

/// Cue 页舞台上请你点头的建议卡的候选（`CueStore.inviteCandidates`）：各按新的在前。
public struct InviteCandidates: Equatable, Sendable {
  /// 没处理的灵感：散放、没归档、不空，14 天内建的。
  public let ideas: [Card]
  /// 7 天内做完、做完后还没看过结果的任务；同一棵做完的子树只出最上面那件。
  public let unseenDone: [Card]
}

extension CueStore {
  /// 搁着的（`shelvedUntil` 没到）两样都不出；到点、出了窗口都会重读。
  public func inviteCandidates(ideas ideaLimit: Int, unseenDone doneLimit: Int) throws -> InviteCandidates {
    let now = timing.now()
    let ideaWindow: TimeInterval = 14 * 86_400, doneWindow: TimeInterval = 7 * 86_400
    let notShelved = "(shelvedUntil IS NULL OR shelvedUntil <= ?)"
    let ideas = try select(
      Card.self,
      where: "(\(Self.cardActive)) AND (\(Self.looseIdea)) AND \(Self.notBlank) AND createdAt >= ? AND \(notShelved)",
      [now.addingTimeInterval(-ideaWindow), now], orderBy: "createdAt DESC, id", limit: ideaLimit)
    let done = try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t LEFT JOIN cards u ON u.id = t.parentID AND \(Self.taskOnBoard("u"))
      WHERE \(Self.taskOnBoard("t")) AND t.completedAt >= ? AND (t.seenAt IS NULL OR t.seenAt < t.completedAt)
        AND (t.shelvedUntil IS NULL OR t.shelvedUntil <= ?) AND (u.id IS NULL OR u.completedAt IS NULL)
      ORDER BY \(Self.recentlyDone) LIMIT ?
      """, [now.addingTimeInterval(-doneWindow), now, doneLimit]
    ) { Card(row: $0) }
    if let next = try db.first("SELECT MIN(shelvedUntil) FROM cards WHERE shelvedUntil > ?", [now], { $0.dateOrNil(0) }) ?? nil { expire(at: next) }
    for idea in ideas { expire(at: idea.createdAt.addingTimeInterval(ideaWindow)) }
    for task in done { if let completed = task.completedAt { expire(at: completed.addingTimeInterval(doneWindow)) } }
    return InviteCandidates(ideas: ideas, unseenDone: done)
  }

  /// 今天先不做：到 `until` 前邀请不再提它。只往后推（同步合并取较晚的，写早了也会被合并盖回）。
  public func shelve(_ id: UUID, until: Date) throws {
    try write { try db.run("UPDATE cards SET shelvedUntil = ?1, \(Self.nudged) WHERE id = ?2 AND (shelvedUntil IS NULL OR shelvedUntil < ?1)", [until, id]) }
  }

  /// 记下你此刻看过这件任务的结果；只在会让 `seenAt` 变晚时写。
  public func markSeen(_ id: UUID) throws {
    try write { try db.run("UPDATE cards SET seenAt = ?1, \(Self.nudged) WHERE id = ?2 AND (seenAt IS NULL OR seenAt < ?1)", [Date.stamp, id]) }
  }

  /// 修改时刻只挪 1 毫秒：要挪才会推送（待推送按它认），挪到此刻则按它排的（灵感的进展、项目顺序、搜索）会因看一眼、划掉而换位置；
  /// 挪得少也不丢并发改动：这两列合并时各取较晚的（`applyVersion`），别处同时的真改动照常胜出整条。
  private static let nudged = "modifiedAt = modifiedAt + 1"
}

import CueText
import Foundation

extension CueStore {
  /// 进回收站；它的下级按原顺序提到它的位置（不连带进回收站）。
  /// 返回回执（`undo` 恢复它、让提上去的下级回到它下面）；不存在或已在回收站时什么都不做、返回 nil。
  @discardableResult
  public func trashCard(_ id: UUID) throws -> CardChange? { try trashCards([id]).first }

  /// 一次删除多条（Mac 上批量选中的灵感）：同一个事务，库只通知一次；每条的规则同 `trashCard`，回执按给出的顺序，跳过的不在里面。
  @discardableResult
  public func trashCards(_ ids: [UUID]) throws -> [CardChange] {
    try write {
      let now = Date.stamp
      return try ids.compactMap { id in
        guard let card = try find(Card.self, id), card.deletedAt == nil else { return nil }
        return .trash(id: id, lifted: try trashRow(card, at: now))
      }
    }
  }

  /// 一条进回收站（在调用方的事务里），返回提到它位置的下级；它上面的定时不再定时（下级提上去、照旧，`endCueSchedules`）。
  @discardableResult
  func trashRow(_ card: Card, at now: Date) throws -> [UUID] {
    let lifted = try liftChildren(of: card, at: now)
    try db.run("UPDATE cards SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, card.id])
    try endCueSchedules(onTasksIn: "SELECT ?2", card.id, at: now)
    if let parent = card.parentID { try settle(around: [parent]) }
    return lifted
  }

  /// 恢复；如果所属项目仍在回收站，卡片回到默认项目，否则会不可见。
  public func restoreCard(_ id: UUID) throws {
    try write { try restoreRow(id) }
  }

  private func restoreRow(_ id: UUID) throws {
    try db.run(
      """
      UPDATE cards SET deletedAt = NULL, modifiedAt = ?,
        projectID = CASE WHEN projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)
                         THEN ? ELSE projectID END
      WHERE id = ?
      """, [Date.stamp, Project.defaultID, id])
    // 恢复回原来的上级下的子任务：上级的会话按叶子的规则放好
    if let parent = try find(Card.self, id)?.parentID { try settle(around: [parent]) }
  }

  /// 拨回一次改动（`trashCard`、`moveCard`、`mergeIdea`、`createTask(fromIdea:)` 的回执），整个拨回是一个事务：
  /// 删除恢复、提上去的下级回到它下面；挪动放回原来的位置；接进任务的灵感恢复、任务正文改回；照灵感新建的任务进回收站、灵感恢复。
  /// 其间已经不在了的下级跳过，原来的前一个同级不在了就排到最前。
  public func undo(_ change: CardChange) throws { try undo([change]) }

  /// 一次拨回多个回执（批量删除的撤销），同一个事务，倒序拨回。
  public func undo(_ changes: [CardChange]) throws {
    try write { for change in changes.reversed() { try undoRow(change) } }
  }

  /// 拨回一个回执（在调用方的事务里）。
  private func undoRow(_ change: CardChange) throws {
    switch change {
    case .trash(let id, let lifted):
      try restoreRow(id)
      try adopt(lifted, by: id)
    case .move(let id, let slot, let after):
      let survivor = try after.flatMap { try find(Card.self, $0)?.id }
      try relocate(id, to: slot, after: survivor)
    case .merge(let idea, let task, let body):
      try db.run("UPDATE cards SET body = ?, modifiedAt = ? WHERE id = ?", [body, Date.stamp, task])
      try restoreRow(idea)
    case .spawn(let idea, let task):
      if let card = try find(Card.self, task), card.deletedAt == nil { _ = try trashRow(card, at: Date.stamp) }
      try restoreRow(idea)
    }
  }

  /// 把这些卡按顺序重新挂到 `parent` 下（已经不在的跳过）。
  private func adopt(_ children: [UUID], by parent: UUID) throws {
    var previous: UUID?
    for child in children where try link(of: child) != nil {
      try relocate(child, to: .under(parent), after: previous)
      previous = child
    }
  }

  /// 离开一条灵感的编辑时：还是空白（`Card.isBlank`）就不留下。任务、写了字或放了图的不动。
  /// 记灵感是先建一条空的再进编辑，这是它的收尾。
  public func dropIfBlank(_ id: UUID) throws {
    try write {
      // 空白的正文不引用图片，没有附件要回收
      guard let card = try find(Card.self, id), !card.isTask, card.isBlank else { return }
      _ = try purgeCards(where: "id = ?", [id])
    }
  }

  /// 永久删除；发送记录保留内容快照。
  public func purgeCard(_ id: UUID) throws {
    try reportingFileFailures { try write { try reclaimAttachments(purgeCards(where: "id = ?", [id])) } }
  }

  /// 清空回收站：单独删除的卡片，以及回收站项目连同其卡片。
  public func emptyTrash() throws {
    try reportingFileFailures { try write {
      let orphaned = try purgeCards(
        where: "deletedAt IS NOT NULL OR projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)")
      try db.run("DELETE FROM projects WHERE deletedAt IS NOT NULL")
      return try reclaimAttachments(orphaned)
    } }
  }

  /// 删卡并在同一事务里清理引用它的记录（同步表没有外键级联）。返回这些卡正文引用过的附件的键，
  /// 由调用方在同一事务里交给 `reclaimAttachments` 判断是否已无人引用。
  func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws -> Set<String> {
    let ids = "SELECT id FROM cards WHERE \(condition)"
    let bodies = try db.query("SELECT body FROM cards WHERE \(condition)", arguments) { $0.text(0) }
    let referenced = Set(bodies.flatMap(CueFormat.attachmentKeys(in:)))
    try db.run("UPDATE sendRecords SET cardID = NULL, modifiedAt = ? WHERE cardID IN (\(ids))", [Date.stamp] + arguments)
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
    return referenced
  }

  /// 删除候选附件中已无人引用的（`isAttachmentReferenced`）：先删文件，成功后再删记录，
  /// 所以记录与文件始终配对；删不掉的文件保留记录并返回其键。
  /// 只看被删的东西引用过的附件，不做全表扫描：刚粘贴、正文尚未保存的附件不能被顺手回收。
  /// 不处理跨设备竞态：另一台设备可能刚好在引用同一个键。
  func reclaimAttachments(_ candidates: Set<String>) throws -> [String] {
    var failed: [String] = []
    for key in candidates.sorted() where try !isAttachmentReferenced(key) {
      guard let parts = AttachmentKey.parts(key) else { continue }
      do { try files.remove(key) } catch {
        failed.append(key)
        continue
      }
      try db.run("DELETE FROM attachments WHERE hash = ? AND format = ?", [parts.hash, parts.format])
    }
    return failed
  }

  /// 对话里你的消息中带附件的行（只有你的消息引用附件）；`?1` 是某个附件的引用（`CueFormat.reference`）或所有引用都含的 `CueFormat.referencePrefix`。
  static let userAttachments = "role = '\(PiChatRole.user.rawValue)' AND instr(text, ?1) > 0"

  /// 还有卡片正文（含回收站里的卡）、发送记录快照（一键重发要用）、对话里你的消息或 Cue 页的对话引用这个附件，或有预览用着这份文件。
  func isAttachmentReferenced(_ key: String) throws -> Bool {
    let referenced = try db.first(
      """
      SELECT 1 FROM cards WHERE instr(body, ?1) > 0
      UNION ALL SELECT 1 FROM sendRecords WHERE instr(content, ?1) > 0
      UNION ALL SELECT 1 FROM piMessages WHERE \(Self.userAttachments)
      UNION ALL SELECT 1 FROM cueMessages WHERE instr(text, ?1) > 0
      """, [CueFormat.reference(key: key)]) { _ in true } != nil
    guard !referenced, let hash = AttachmentKey.parts(key)?.hash else { return referenced }
    return try db.query("SELECT name FROM previews WHERE hash = ?", [hash]) { $0.text(0) }.contains { AttachmentKey.make(hash: hash, name: $0) == key }
  }

  /// 事务已提交后，把删不掉文件的键作为错误报告（永久删除本身已生效）。
  func reportingFileFailures(_ body: () throws -> [String]) throws {
    let failed = try body()
    if !failed.isEmpty { throw CueStoreError.attachmentFilesNotRemoved(failed) }
  }
}

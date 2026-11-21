import CueText
import Foundation

extension CueStore {
  @discardableResult
  public func trashCard(_ id: UUID) throws -> CardChange? { try trashCards([id]).first }

  @discardableResult
  public func trashCards(_ ids: [UUID]) throws -> [CardChange] {
    try write {
      let now = Date.stamp
      return try ids.compactMap { id in
        guard let card = try find(Card.self, id), card.deletedAt == nil else { return nil }
        return try trashRow(card, at: now)
      }
    }
  }

  @discardableResult
  func trashRow(_ card: Card, at now: Date) throws -> CardChange {
    let lifted = try liftChildren(of: card, at: now)
    try db.run("UPDATE cards SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, card.id])
    let schedules = try endCueSchedules(onTasksIn: "SELECT ?2", card.id, at: now)
    if let parent = card.parentID { try settle(around: [parent]) }
    return .trash(id: card.id, lifted: lifted, schedules: schedules)
  }

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
    if let parent = try find(Card.self, id)?.parentID { try settle(around: [parent]) }
  }

  public func undo(_ change: CardChange) throws { try undo([change]) }

  public func undo(_ changes: [CardChange]) throws {
    try write { for change in changes.reversed() { try undoRow(change) } }
  }

  public func undo(_ change: CardChange, of id: UUID, stillAt slot: CardSlot, after previous: UUID?) throws {
    try write {
      guard let current = try link(of: id), try position(of: id, current) == (slot, previous) else { throw CueStoreError.changedSinceUndo }
      try undoRow(change)
    }
  }

  private func undoRow(_ change: CardChange) throws {
    switch change {
    case .trash(let id, let lifted, let schedules):
      let left = try find(Card.self, id).map { CardLinks.Link(parent: $0.parentID, project: $0.projectID, isTask: $0.isTask) }
      try restoreRow(id)
      try adopt(lifted, by: id, from: left)
      try restoreCueSchedules(schedules)
    case .archive(let id, let time, let schedules):
      guard try find(Card.self, id)?.archivedAt == time else { return }
      try unarchiveRow(id, archivedAt: time)
      try restoreCueSchedules(schedules)
    case .move(let id, let slot, let after):
      let survivor = try after.flatMap { try find(Card.self, $0)?.id }
      try relocate(id, to: slot, after: survivor)
    case .merge(let idea, let task, let body, let modifiedAt):
      guard let current = try find(Card.self, task), current.modifiedAt == modifiedAt else { throw CueStoreError.changedSinceUndo }
      try db.run("UPDATE cards SET body = ?, modifiedAt = ? WHERE id = ?", [body, Date.stamp, task])
      try restoreRow(idea)
    case .spawn(let idea, let task, let modifiedAt):
      if let card = try find(Card.self, task), card.deletedAt == nil {
        guard card.modifiedAt == modifiedAt else { throw CueStoreError.changedSinceUndo }
        _ = try trashRow(card, at: Date.stamp)
      }
      try restoreRow(idea)
    }
  }

  private func adopt(_ children: [UUID], by parent: UUID, from left: CardLinks.Link?) throws {
    guard let left else { return }
    var previous: UUID?
    for child in children {
      guard let now = try link(of: child), now.parent == left.parent, now.project == left.project else { continue }
      try relocate(child, to: .under(parent), after: previous)
      previous = child
    }
  }

  public func dropIfBlank(_ id: UUID) throws {
    try write {
      guard let card = try find(Card.self, id), !card.isTask, card.isBlank else { return }
      _ = try purgeCards(where: "id = ?", [id])
    }
  }

  public func purgeCard(_ id: UUID) throws {
    try removingFiles { try write { try reclaimAttachments(purgeCards(where: "id = ?", [id])) } }
  }

  public func emptyTrash() throws {
    try removingFiles { try write {
      let orphaned = try purgeCards(
        where: "deletedAt IS NOT NULL OR projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)")
      try dropProjects(db.query("SELECT id FROM projects WHERE deletedAt IS NOT NULL") { $0.uuid(0) })
      return try reclaimAttachments(orphaned)
    } }
  }

  func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws -> Set<String> {
    let ids = "SELECT id FROM cards WHERE \(condition)"
    let bodies = try db.query("SELECT body FROM cards WHERE \(condition)", arguments) { $0.text(0) }
    let referenced = Set(bodies.flatMap(CueFormat.attachmentKeys(in:)))
    try db.run("UPDATE sendRecords SET cardID = NULL, modifiedAt = ? WHERE cardID IN (\(ids))", [Date.stamp] + arguments)
    try releaseDeliveryBindings(of: db.query(ids, arguments) { $0.uuid(0) })
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
    return referenced
  }

  func reclaimAttachments(_ candidates: Set<String>) throws -> [String] {
    var reclaimed: [String] = []
    for key in candidates.sorted() where try !isAttachmentReferenced(key) {
      guard let parts = AttachmentKey.parts(key) else { continue }
      try db.run("DELETE FROM attachments WHERE hash = ? AND format = ?", [parts.hash, parts.format])
      reclaimed.append(key)
    }
    return reclaimed
  }

  static let userAttachments = "role = '\(ChatRole.user.rawValue)' AND instr(text, ?1) > 0"

  static let toolImages = "tools IS NOT NULL AND instr(tools, ?1) > 0"

  func isAttachmentReferenced(_ key: String) throws -> Bool {
    let referenced = try db.first(
      """
      SELECT 1 FROM cards WHERE instr(body, ?1) > 0
      UNION ALL SELECT 1 FROM sendRecords WHERE instr(content, ?1) > 0
      UNION ALL SELECT 1 FROM piMessages WHERE \(Self.userAttachments)
      UNION ALL SELECT 1 FROM piMessages WHERE tools IS NOT NULL AND instr(tools, ?2) > 0
      UNION ALL SELECT 1 FROM piSessionStates WHERE pendingTools IS NOT NULL AND instr(pendingTools, ?2) > 0
      UNION ALL SELECT 1 FROM cueMessages WHERE instr(text, ?1) > 0
      """, [CueFormat.reference(key: key), "\"\(key)\""]) { _ in true } != nil
    guard !referenced, let hash = AttachmentKey.parts(key)?.hash else { return referenced }
    // 开会话请求的开场存在 JSON 里（斜杠被转义），按引用原文找不到：先按键里的哈希粗筛，再按请求自己的规则精判
    if try select(DeliveryRequest.self, where: "instr(content, ?) > 0", [hash]).contains(where: { $0.attachmentKeys.contains(key) }) { return true }
    return try db.query("SELECT name FROM previews WHERE hash = ?", [hash]) { $0.text(0) }.contains { AttachmentKey.make(hash: hash, name: $0) == key }
  }

  func removingFiles(_ body: () throws -> [String]) throws {
    let keys = try body()
    guard !keys.isEmpty else { return }
    var failed: [String] = []
    _ = try reclaimFiles(candidates: { Set(keys) }) { key, _ in failed.append(key) }
    if !failed.isEmpty { throw CueStoreError.attachmentFilesNotRemoved(failed) }
  }
}

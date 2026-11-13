import CueText
import Foundation

extension CueStore {
  /// 进回收站；它的下级按原顺序提到它的位置（不连带进回收站）。
  /// 返回回执（`undo` 恢复它、让提上去的下级回到它下面）；不存在或已在回收站时什么都不做、返回 nil。
  @discardableResult
  public func trashCard(_ id: UUID) throws -> CardChange? { try trashCards([id]).first }

  /// 一次删除多条（Mac 上批量选中的灵感）：同一个事务，库只通知一次；回执按给出的顺序，跳过的不在里面。
  @discardableResult
  public func trashCards(_ ids: [UUID]) throws -> [CardChange] {
    try write {
      let now = Date.stamp
      return try ids.compactMap { id in
        guard let card = try find(Card.self, id), card.deletedAt == nil else { return nil }
        let lifted = try trashRow(card, at: now)
        if card.completedAt == nil { try endUnusedSessions(of: id, cue: false) }
        return .trash(id: id, lifted: lifted)
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

  /// 拨回一次改动的回执，整个拨回是一个事务；合并与新建的回执带着任务当时的修改时刻，之后又改过就抛 `changedSinceUndo`、什么都不撤。其间已经不在了、挪去别处的下级跳过，原来的前一个同级不在了就排到最前。
  public func undo(_ change: CardChange) throws { try undo([change]) }

  /// 一次拨回多个回执（批量删除的撤销），同一个事务，倒序拨回。
  public func undo(_ changes: [CardChange]) throws {
    try write { for change in changes.reversed() { try undoRow(change) } }
  }

  /// 隔了很久才来的撤销（系统撤销）拨回一次移动：`id` 还在那次挪到的地方（同一个上级或项目、同一个前一个同级）才拨，否则抛 `changedSinceUndo`、什么都不撤——
  /// 其间又挪过的，照回执放回去会盖掉后来那一次。按位置认、不按修改时刻：连着撤两步时，撤后一步本身就改了修改时刻，前一步照样要撤得回。
  public func undo(_ change: CardChange, of id: UUID, stillAt slot: CardSlot, after previous: UUID?) throws {
    try write {
      guard let current = try link(of: id), try position(of: id, current) == (slot, previous) else { throw CueStoreError.changedSinceUndo }
      try undoRow(change)
    }
  }

  private func undoRow(_ change: CardChange) throws {
    switch change {
    case .trash(let id, let lifted):
      // 提上去的下级落在它原来的位置（它的上级下，或它那个项目的顶层）：还在那里的才收回来，其间挪去别处的不动
      let left = try find(Card.self, id).map { CardLinks.Link(parent: $0.parentID, project: $0.projectID, isTask: $0.isTask) }
      try restoreRow(id)
      try adopt(lifted, by: id, from: left)
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

  /// 离开一条灵感的编辑时：还是空白（`Card.isBlank`）就不留下。任务、写了字或放了图的不动。
  public func dropIfBlank(_ id: UUID) throws {
    try write {
      // 空白的正文不引用图片，没有附件要回收
      guard let card = try find(Card.self, id), !card.isTask, card.isBlank else { return }
      _ = try purgeCards(where: "id = ?", [id])
    }
  }

  /// 永久删除；发送记录保留内容快照。
  public func purgeCard(_ id: UUID) throws {
    try removingFiles { try write { try reclaimAttachments(purgeCards(where: "id = ?", [id])) } }
  }

  public func emptyTrash() throws {
    try removingFiles { try write {
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
    try releaseDeliveryBindings(of: db.query(ids, arguments) { $0.uuid(0) })
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
    return referenced
  }

  /// 候选附件中已无人引用的（`isAttachmentReferenced`）：在事务里删记录，返回它们的键，文件由 `removingFiles` 在提交后删——
  /// 事务中途失败回滚时，记录还在、文件也还在。提交后没删成的文件成了没记录没引用的游离文件，下次启动的 `removeStrayFiles` 会收走。
  /// 只看被删的东西引用过的附件，不做全表扫描：别的没人用的文件归启动清理。
  /// 不处理跨设备竞态：另一台设备可能刚好在引用同一个键。
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

  /// 一轮经过里带图的（`?1` 是 `Tools.imagesField` 或某个键加引号）：工具结果里的图只记在经过上（`ChatMessage.Tools.Item.images`）。
  static let toolImages = "tools IS NOT NULL AND instr(tools, ?1) > 0"

  /// 还有卡片正文（含回收站里的卡）、发送记录快照（一键重发要用）、还在库里的投送请求（等派发的、等重发的，引用只读 `DeliveryRequest.attachmentKeys`）、
  /// 对话里你的消息、一轮经过里的工具图（做完的与在跑的）或 Cue 页的对话引用这个附件，或有预览用着这份文件。
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

  /// 先提交记录删除，再在统一回收边界复核；回滚时不碰文件。
  func removingFiles(_ body: () throws -> [String]) throws {
    let keys = try body()
    guard !keys.isEmpty else { return }
    var failed: [String] = []
    _ = try reclaimFiles(candidates: { Set(keys) }) { key, _ in failed.append(key) }
    if !failed.isEmpty { throw CueStoreError.attachmentFilesNotRemoved(failed) }
  }
}

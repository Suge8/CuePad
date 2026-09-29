import Foundation

// MARK: 项目

extension CueStore {
  /// 新项目追加在末尾。
  public func createProject(
    name: String, color: String, icon: String? = nil
  ) throws -> Project {
    try write {
      let last = try db.first("SELECT MAX(sortKey) FROM projects") { $0.textOrNil(0) } ?? nil
      let now = Date.stamp
      let project = Project(
        id: UUID(), name: name, icon: icon, color: color,
        sortKey: SortKey.after(last), isPinned: false, goalCardID: nil, deletedAt: nil, createdAt: now, modifiedAt: now)
      try insert(project)
      return project
    }
  }

  /// 改名称、颜色、图标、置顶。排序键、删除状态、目标卡对调用方只读，各有专门的方法（编译期保证）。
  public func updateProject(_ id: UUID, _ edit: @Sendable (inout Project) -> Void) throws {
    try write {
      guard var project = try find(Project.self, id) else { throw CueStoreError.notFound }
      edit(&project)
      project.modifiedAt = Date.stamp
      try update(project)
    }
  }

  /// 把项目移到 `previous` 之后（nil = 最前）。
  public func moveProject(_ id: UUID, after previous: UUID?) throws {
    try write { try place(.projects, scope: "deletedAt IS NULL", id: id, after: previous) }
  }

  /// 设置项目目标卡（nil = 取消）。目标必须是该项目里未删除的卡。
  public func setGoal(_ card: UUID?, for project: UUID) throws {
    try write {
      if let card {
        let valid = try db.first(
          "SELECT 1 FROM cards WHERE id = ? AND projectID = ? AND deletedAt IS NULL", [card, project]) { _ in true }
        guard valid != nil else { throw CueStoreError.invalidGoal }
      }
      try db.run("UPDATE projects SET goalCardID = ?, modifiedAt = ? WHERE id = ?", [card, Date.stamp, project])
      guard db.changes > 0 else { throw CueStoreError.notFound }
    }
  }

  /// 进回收站；它的卡片随之隐藏（由项目推导），卡片行不动。
  public func trashProject(_ id: UUID) throws {
    try write {
      try db.run(
        "UPDATE projects SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2 AND deletedAt IS NULL",
        [Date.stamp, id])
    }
  }

  public func restoreProject(_ id: UUID) throws {
    try write {
      try db.run("UPDATE projects SET deletedAt = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, id])
    }
  }

  /// 永久删除：连同随项目进回收站的卡片；更早单独进回收站的卡片留在回收站（归入未归档）；
  /// 任务归为全局。
  public func purgeProject(_ id: UUID) throws {
    try reportingFileFailures { try write {
      let now = Date.stamp
      let orphaned = try purgeCards(where: "projectID = ? AND deletedAt IS NULL", [id])
      try db.run("UPDATE cards SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, id])
      try db.run("UPDATE tasks SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, id])
      try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [id])
      try db.run("DELETE FROM projects WHERE id = ?", [id])
      return try reclaimAttachments(orphaned)
    } }
  }
}

// MARK: 项目目录（本机）

extension CueStore {
  /// 绑定项目的代码目录（nil = 解除）。目录因设备而异，不同步。
  public func setDirectory(_ directory: String?, for project: UUID) throws {
    try write {
      guard let directory else {
        try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [project])
        return
      }
      try db.run(
        """
        INSERT INTO projectDirectories (projectID, directory) VALUES (?, ?)
        ON CONFLICT(projectID) DO UPDATE SET directory = excluded.directory
        """, [project, directory])
    }
  }

  public func directory(of project: UUID) throws -> String? {
    try db.first("SELECT directory FROM projectDirectories WHERE projectID = ?", [project]) { $0.text(0) }
  }

  /// 本机所有项目的目录绑定。
  public func projectDirectories() throws -> [UUID: String] {
    Dictionary(
      uniqueKeysWithValues: try db.query("SELECT projectID, directory FROM projectDirectories") {
        ($0.uuid(0), $0.text(1))
      })
  }
}

// MARK: 卡片

extension CueStore {
  /// 新卡片放在所在项目（nil = 未归档）的最前。
  public func createCard(in project: UUID?, body: String = "") throws -> Card {
    try write {
      let first = try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID IS ?", [project]) {
        $0.textOrNil(0)
      } ?? nil
      let now = Date.stamp
      let card = Card(
        id: UUID(), projectID: project, body: body, numbering: .none, isFavorite: false,
        variableValues: [:], sortKey: SortKey.before(first), deletedAt: nil, createdAt: now,
        modifiedAt: now)
      try insert(card)
      return card
    }
  }

  /// 改正文、编号方式、收藏、变量取值。归属项目、排序键、删除状态对调用方只读，各有专门的方法（编译期保证）。
  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
    }
  }

  /// 移到 `project`（nil = 未归档）里 `previous` 之后（nil = 最前）。
  public func moveCard(_ id: UUID, to project: UUID?, after previous: UUID?) throws {
    try write {
      try db.run("UPDATE cards SET projectID = ? WHERE id = ?", [project, id])
      guard db.changes > 0 else { throw CueStoreError.notFound }
      try clearGoal(where: "id = ?", [id], exceptProject: project)
      try place(.cards, scope: "deletedAt IS NULL AND projectID IS ?", [project], id: id, after: previous)
    }
  }

  public func trashCard(_ id: UUID) throws {
    try write {
      try clearGoal(where: "id = ?", [id])
      try db.run(
        "UPDATE cards SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2 AND deletedAt IS NULL", [Date.stamp, id])
    }
  }

  /// 恢复；如果所属项目仍在回收站，卡片回到未归档，否则会不可见。
  public func restoreCard(_ id: UUID) throws {
    try write {
      try db.run(
        """
        UPDATE cards SET deletedAt = NULL, modifiedAt = ?,
          projectID = CASE WHEN projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)
                           THEN NULL ELSE projectID END
        WHERE id = ?
        """, [Date.stamp, id])
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

  /// 目标卡离开（进回收站、删除、移出项目）时，在同一事务里清空指向它的项目目标。
  /// 清空而不是读时推导：存下的值始终真实，整行读改写（updateProject）不会丢它，
  /// 同步时也只是一次普通字段变更。代价：卡片恢复后不自动变回目标。
  private func clearGoal(
    where condition: String, _ arguments: [any SQLBindable], exceptProject keep: UUID? = nil
  ) throws {
    try db.run(
      """
      UPDATE projects SET goalCardID = NULL, modifiedAt = ?
      WHERE goalCardID IN (SELECT id FROM cards WHERE \(condition)) AND id IS NOT ?
      """, [Date.stamp] + arguments + [keep])
  }

  /// 删卡并在同一事务里清理引用它的记录（同步表没有外键级联）。返回这些卡正文引用过的图片哈希，
  /// 由调用方在同一事务里交给 `reclaimAttachments` 判断是否已无人引用。
  private func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws -> Set<String> {
    let ids = "SELECT id FROM cards WHERE \(condition)"
    try clearGoal(where: condition, arguments)
    let bodies = try db.query("SELECT body FROM cards WHERE \(condition)", arguments) { $0.text(0) }
    let referenced = Set(bodies.flatMap { $0.matches(of: /cuepad:\/\/img\/([0-9a-f]{64})/).map { String($0.output.1) } })
    try db.run("DELETE FROM cardTags WHERE cardID IN (\(ids))", arguments)
    try db.run("UPDATE sendRecords SET cardID = NULL, modifiedAt = ? WHERE cardID IN (\(ids))", [Date.stamp] + arguments)
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
    return referenced
  }

  /// 删除候选图片中已不被任何卡片正文（含回收站里的卡）和发送记录快照（一键重发要用）引用的：先删文件，成功后再删记录，
  /// 所以记录与文件始终配对；删不掉的文件保留记录并返回其哈希。
  /// 只看被删卡片引用过的图片，不做全表扫描：刚粘贴、正文尚未保存的图片不能被顺手回收。
  /// 不处理跨设备竞态：另一台设备可能刚好在引用同一哈希，阶段 3 接入同步时再处理。
  private func reclaimAttachments(_ candidates: Set<String>) throws -> [String] {
    var failed: [String] = []
    for hash in candidates.sorted() {
      let used = try db.first(
        """
        SELECT 1 FROM cards WHERE instr(body, ?1) > 0
        UNION ALL SELECT 1 FROM sendRecords WHERE instr(content, ?1) > 0
        """, ["cuepad://img/\(hash)"]) { _ in true }
      if used != nil { continue }
      do { try files.remove(hash: hash) } catch {
        failed.append(hash)
        continue
      }
      try db.run("DELETE FROM attachments WHERE hash = ?", [hash])
    }
    return failed
  }

  /// 事务已提交后，把删不掉文件的哈希作为错误报告（永久删除本身已生效）。
  private func reportingFileFailures(_ body: () throws -> [String]) throws {
    let failed = try body()
    if !failed.isEmpty { throw CueStoreError.attachmentFilesNotRemoved(failed) }
  }
}

// MARK: 标签

extension CueStore {
  /// 给卡片加标签；同名标签复用，重复添加无效果。
  @discardableResult
  public func addTag(_ name: String, to card: UUID) throws -> Tag {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw CueStoreError.blankTagName }
    return try write {
      let now = Date.stamp
      let existing = try select(Tag.self, where: "name = ?", [name], orderBy: "createdAt, id").first
      let tag = existing ?? Tag(id: UUID(), name: name, color: nil, createdAt: now, modifiedAt: now)
      if existing == nil { try insert(tag) }
      let linked = try db.first("SELECT 1 FROM cardTags WHERE cardID = ? AND tagID = ?", [card, tag.id]) { _ in true }
      if linked == nil {
        try insert(CardTag(id: UUID(), cardID: card, tagID: tag.id, createdAt: now, modifiedAt: now))
      }
      return tag
    }
  }

  public func removeTag(_ tag: UUID, from card: UUID) throws {
    try write { try db.run("DELETE FROM cardTags WHERE cardID = ? AND tagID = ?", [card, tag]) }
  }
}

// MARK: 任务

extension CueStore {
  /// 新任务放在未完成任务的最前。
  public func createTask(_ content: String, in project: UUID? = nil) throws -> CueTask {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CueStoreError.blankTaskContent
    }
    return try write {
      let first = try db.first("SELECT MIN(sortKey) FROM tasks WHERE completedAt IS NULL") {
        $0.textOrNil(0)
      } ?? nil
      let now = Date.stamp
      let task = CueTask(
        id: UUID(), content: content, projectID: project, sortKey: SortKey.before(first),
        completedAt: nil, piSessionID: nil, createdAt: now, modifiedAt: now)
      try insert(task)
      return task
    }
  }

  /// 改内容、勾选完成（`completedAt`）、所属项目、关联 Pi 会话；顺序用 `moveTask`。
  public func updateTask(_ id: UUID, _ edit: @Sendable (inout CueTask) -> Void) throws {
    try write {
      guard var task = try find(CueTask.self, id) else { throw CueStoreError.notFound }
      edit(&task)
      guard !task.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CueStoreError.blankTaskContent
      }
      task.modifiedAt = Date.stamp
      try update(task)
    }
  }

  /// 把未完成任务移到 `previous` 之后（nil = 最前）。
  public func moveTask(_ id: UUID, after previous: UUID?) throws {
    try write { try place(.tasks, scope: "completedAt IS NULL", id: id, after: previous) }
  }

  public func deleteTask(_ id: UUID) throws {
    try write {
      try db.run("UPDATE sendRecords SET taskID = NULL, modifiedAt = ? WHERE taskID = ?", [Date.stamp, id])
      try db.run("DELETE FROM tasks WHERE id = ?", [id])
    }
  }
}

// MARK: 发送记录、附件、Pi 会话索引

extension CueStore {
  /// 记录一次投送或复制：内容快照、目标、时间。
  @discardableResult
  public func recordSend(
    _ content: String, to target: SendTarget, card: UUID? = nil, task: UUID? = nil
  ) throws -> SendRecord {
    try write {
      let now = Date.stamp
      let record = SendRecord(
        id: UUID(), content: content, targetKind: target.kind, targetName: target.name,
        targetRef: target.ref, cardID: card, taskID: task, sentAt: now, modifiedAt: now)
      try insert(record)
      return record
    }
  }

  /// 登记图片附件元数据；同一内容哈希只有一条。
  @discardableResult
  public func registerAttachment(hash: String, byteCount: Int, format: String) throws -> Attachment {
    try write {
      if let existing = try select(Attachment.self, where: "hash = ?", [hash], orderBy: "createdAt, id").first {
        return existing
      }
      let now = Date.stamp
      let attachment = Attachment(
        id: UUID(), hash: hash, byteCount: byteCount, format: format, createdAt: now, modifiedAt: now)
      try insert(attachment)
      return attachment
    }
  }

  /// 插入或更新会话索引；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。仅本机，不同步。
  public func upsertPiSession(_ session: PiSession, checkpoint: Data? = nil) throws {
    try write {
      let assignments = PiSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = (PiSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessions (\(PiSession.columns.joined(separator: ", ")), checkpoint) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments),
          checkpoint = COALESCE(excluded.checkpoint, piSessions.checkpoint)
        """, session.bindings + [checkpoint])
    }
  }
}

// MARK: 排序

extension CueStore {
  /// 把 `id` 放到同一范围内 `previous` 之后：只改它自己的排序键；
  /// 两侧键相同（多设备并发产生）时，重排该范围内所有键。
  fileprivate func place(
    _ table: Table, scope: String, _ scopeArguments: [any SQLBindable] = [], id: UUID, after previous: UUID?
  ) throws {
    let siblings = try db.query(
      "SELECT id, sortKey FROM \(table.rawValue) WHERE (\(scope)) AND id != ? ORDER BY sortKey, id",
      scopeArguments + [id]
    ) { (id: $0.uuid(0), key: $0.text(1)) }

    var position = 0
    if let previous {
      guard let index = siblings.firstIndex(where: { $0.id == previous }) else {
        throw CueStoreError.notFound
      }
      position = index + 1
    }
    let lower = position > 0 ? siblings[position - 1].key : nil
    let upper = position < siblings.count ? siblings[position].key : nil

    let assignments: [(id: UUID, key: String)]
    if let key = SortKey.between(lower, upper) {
      assignments = [(id, key)]
    } else {
      var order = siblings.map(\.id)
      order.insert(id, at: position)
      assignments = Array(zip(order, SortKey.sequence(count: order.count)))
    }
    let now = Date.stamp
    for (rowID, key) in assignments {
      try db.run("UPDATE \(table.rawValue) SET sortKey = ?, modifiedAt = ? WHERE id = ?", [key, now, rowID])
      guard db.changes > 0 else { throw CueStoreError.notFound }
    }
  }
}

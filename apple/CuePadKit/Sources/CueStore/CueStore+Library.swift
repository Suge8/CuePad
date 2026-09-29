import Foundation

// MARK: 项目

extension CueStore {
  /// 新项目追加在末尾。
  public func createProject(
    name: String, color: String, icon: String? = nil, directory: String? = nil
  ) throws -> Project {
    try write {
      let last = try db.first("SELECT MAX(sortKey) FROM projects") { $0.textOrNil(0) } ?? nil
      let now = Date.stamp
      let project = Project(
        id: UUID(), name: name, icon: icon, color: color, directory: directory,
        sortKey: SortKey.after(last), isPinned: false, deletedAt: nil, createdAt: now, modifiedAt: now)
      try insert(project)
      return project
    }
  }

  /// 改名称、颜色、图标、目录、置顶等字段；顺序与删除用专门的方法。
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
    try write {
      let now = Date.stamp
      try purgeCards(where: "projectID = ? AND deletedAt IS NULL", [id])
      try db.run("UPDATE cards SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, id])
      try db.run("UPDATE tasks SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, id])
      try db.run("DELETE FROM projects WHERE id = ?", [id])
    }
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

  /// 改正文、编号方式、收藏、变量取值等字段；归属、顺序与删除用专门的方法。
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
      try place(.cards, scope: "deletedAt IS NULL AND projectID IS ?", [project], id: id, after: previous)
    }
  }

  public func trashCard(_ id: UUID) throws {
    try write {
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
    try write { try purgeCards(where: "id = ?", [id]) }
  }

  /// 清空回收站：单独删除的卡片，以及回收站项目连同其卡片。
  public func emptyTrash() throws {
    try write {
      try purgeCards(
        where: "deletedAt IS NOT NULL OR projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)")
      try db.run("DELETE FROM projects WHERE deletedAt IS NOT NULL")
    }
  }

  /// 删卡并在同一事务里清理引用它的记录（同步表没有外键级联）。
  private func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws {
    let ids = "SELECT id FROM cards WHERE \(condition)"
    try db.run("DELETE FROM cardTags WHERE cardID IN (\(ids))", arguments)
    try db.run("UPDATE sendRecords SET cardID = NULL, modifiedAt = ? WHERE cardID IN (\(ids))", [Date.stamp] + arguments)
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
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

  /// 插入或更新会话索引（含读取偏移）；仅本机，不同步。
  public func upsertPiSession(_ session: PiSession) throws {
    try write {
      let assignments = PiSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
      let placeholders = PiSession.columns.map { _ in "?" }.joined(separator: ", ")
      try db.run(
        """
        INSERT INTO piSessions (\(PiSession.columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(id) DO UPDATE SET \(assignments)
        """, session.bindings)
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

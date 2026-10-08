import CueText
import Foundation

// MARK: 项目

extension CueStore {
  public func createProject(
    name: String, color: String, icon: String? = nil
  ) throws -> Project {
    try write {
      let now = Date.stamp
      let project = Project(
        id: UUID(), name: name, icon: icon, color: color,
        isPinned: false, intro: nil, deletedAt: nil, createdAt: now, modifiedAt: now)
      try insert(project)
      return project
    }
  }

  /// 改名称、介绍、颜色、图标、置顶。删除状态对调用方只读，有专门的方法（编译期保证）。
  public func updateProject(_ id: UUID, _ edit: @Sendable (inout Project) -> Void) throws {
    try write {
      guard var project = try find(Project.self, id) else { throw CueStoreError.notFound }
      edit(&project)
      project.modifiedAt = Date.stamp
      try update(project)
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

  /// 永久删除：连同随项目进回收站的卡片；更早单独进回收站的卡片留在回收站（归入未分类）。
  public func purgeProject(_ id: UUID) throws {
    try reportingFileFailures { try write {
      let now = Date.stamp
      let orphaned = try purgeCards(where: "projectID = ? AND deletedAt IS NULL", [id])
      try db.run("UPDATE cards SET projectID = NULL, modifiedAt = ? WHERE projectID = ?", [now, id])
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

// MARK: 卡片（灵感与任务）

extension CueStore {
  /// 新灵感放在所在项目（nil = 未分类）的最前。项目必须存在且未在回收站，否则抛 `invalidProject`。
  public func createCard(in project: UUID?, body: String = "") throws -> Card {
    try write {
      try requireLiveProject(project)
      return try insertCard(body, project: project, parent: nil, todo: false, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  /// 新任务（要做的卡片）放在所在项目顶层的最前。正文不能为空，否则抛 `blankTaskContent`。
  public func createTask(_ body: String, in project: UUID?) throws -> Card {
    try requireContent(body)
    return try write {
      try requireLiveProject(project)
      return try insertCard(body, project: project, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: project)))
    }
  }

  /// 新子任务放在 `parent` 的下级最后，项目随它。上级不是任务抛 `invalidParent`，已在第 `Card.maxDepth` 级抛 `taskTooDeep`。
  public func createTask(_ body: String, under parent: UUID) throws -> Card {
    try requireContent(body)
    return try write {
      let tree = try CardLinks(db)
      guard let link = tree.links[parent], link.isTask else { throw CueStoreError.invalidParent }
      guard tree.level(of: parent) < Card.maxDepth else { throw CueStoreError.taskTooDeep }
      let last = try db.first("SELECT MAX(sortKey) FROM cards WHERE parentID = ?", [parent]) { $0.textOrNil(0) } ?? nil
      return try insertCard(body, project: link.project, parent: parent, todo: true, sortKey: SortKey.after(last))
    }
  }

  /// 改正文、置顶、变量取值。归属、结构、状态、删除对调用方只读，各有专门的方法（编译期保证）。
  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
      try registerImages(in: card.body)
    }
  }

  /// 设为任务 / 改回灵感。设为任务：成为待办的任务。改回：回到灵感（状态与会话关联清掉），它的下级按原顺序提到它的位置。
  public func setTodo(_ id: UUID, _ on: Bool) throws {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard card.isTask != on else { return }
      let now = Date.stamp
      if on {
        try db.run("UPDATE cards SET todoAt = ?1, startedAt = NULL, completedAt = NULL, modifiedAt = ?1 WHERE id = ?2", [now, id])
      } else {
        try liftChildren(of: card, at: now)
        try db.run(
          "UPDATE cards SET todoAt = NULL, startedAt = NULL, completedAt = NULL, piSessionID = NULL, modifiedAt = ? WHERE id = ?", [now, id])
      }
    }
  }

  /// 改任务的状态：进行中记开始时间（已有的保留），完成记完成时间（保留开始时间）并连带没完成的下级任务，回到待办两个都清空。
  /// 灵感没有状态，抛 `notATask`。
  /// 归档：连同下级一起（已归档的保留原时刻）。
  public func archive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id] + (try CardLinks(db).descendants(of: id)), at: Date.stamp)
    }
  }

  /// 从归档取回：连同下级一起回到原处。
  public func unarchive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id] + (try CardLinks(db).descendants(of: id)), at: nil)
    }
  }

  /// 任务页"最近完成"的一键归档：已完成的顶层任务（及其下级）全部归档，返回归档了几条任务。
  /// 没做完的任务下已完成的子任务算在上级的进度里，不单独归档。
  public func archiveCompletedTasks() throws -> Int {
    try write {
      let done = try db.query(
        """
        SELECT t.id FROM cards t
        WHERE t.todoAt IS NOT NULL AND t.completedAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL
          AND (t.parentID IS NULL OR t.parentID NOT IN (SELECT id FROM cards WHERE todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL))
        """
      ) { $0.uuid(0) }
      let links = try CardLinks(db), now = Date.stamp
      for id in done { try setArchived([id] + links.descendants(of: id), at: now) }
      return done.count
    }
  }

  private func setArchived(_ ids: [UUID], at time: Date?) throws {
    let now = Date.stamp
    try db.run(
      """
      UPDATE cards SET archivedAt = ?1, modifiedAt = ?2
      WHERE id IN (SELECT value FROM json_each(?3)) AND (archivedAt IS NULL) = (?1 IS NOT NULL)
      """, [time, now, Self.idList(ids)])
  }

  public func setStatus(_ id: UUID, _ status: TaskStatus) throws {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      guard let current = card.status else { throw CueStoreError.notATask }
      guard current != status else { return }
      let now = Date.stamp
      switch status {
      case .todo: try db.run("UPDATE cards SET startedAt = NULL, completedAt = NULL, modifiedAt = ? WHERE id = ?", [now, id])
      case .inProgress:
        try db.run("UPDATE cards SET startedAt = COALESCE(startedAt, ?1), completedAt = NULL, modifiedAt = ?1 WHERE id = ?2", [now, id])
      case .done:
        let subtree = [id] + (try CardLinks(db).descendants(of: id))
        try db.run(
          """
          UPDATE cards SET completedAt = ?1, modifiedAt = ?1
          WHERE completedAt IS NULL AND todoAt IS NOT NULL AND id IN (SELECT value FROM json_each(?2))
          """, [now, Self.idList(subtree)])
      }
    }
  }

  /// 挪到 `slot` 里 `previous` 之后（nil = 最前），下级随它走、项目随新位置。卡片墙上的排序、换项目、缩进、
  /// 挂成子任务或相关灵感都是它。只能挂到任务下、不能挂到自己或自己的下级下（`invalidParent`），整棵子树超过 `Card.maxDepth` 级抛 `taskTooDeep`。
  public func moveCard(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws {
    try write {
      let tree = try CardLinks(db)
      guard let current = tree.links[id] else { throw CueStoreError.notFound }
      let destination: CardLinks.Link
      switch slot {
      case .top(let project):
        try requireLiveProject(project)
        destination = CardLinks.Link(parent: nil, project: project, isTask: current.isTask)
      case .under(let parent):
        guard let target = tree.links[parent], target.isTask, parent != id, !tree.ancestors(of: parent).contains(id) else {
          throw CueStoreError.invalidParent
        }
        guard tree.level(of: parent) + tree.height(of: id) <= Card.maxDepth else { throw CueStoreError.taskTooDeep }
        destination = CardLinks.Link(parent: parent, project: target.project, isTask: current.isTask)
      }
      let now = Date.stamp
      try db.run("UPDATE cards SET parentID = ?, modifiedAt = ? WHERE id = ?", [destination.parent, now, id])
      if destination.project != current.project {
        try db.run(
          "UPDATE cards SET projectID = ?, modifiedAt = ? WHERE id IN (SELECT value FROM json_each(?))",
          [destination.project, now, Self.idList([id] + tree.descendants(of: id))])
      }
      try place(.cards, scope: Self.siblingScope(destination), [destination.parent ?? destination.project], id: id, after: previous)
    }
  }

  /// 进回收站；它的下级按原顺序提到它的位置（不连带进回收站）。
  public func trashCard(_ id: UUID) throws {
    try write {
      guard let card = try find(Card.self, id), card.deletedAt == nil else { return }
      let now = Date.stamp
      try liftChildren(of: card, at: now)
      try db.run("UPDATE cards SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, id])
    }
  }

  /// 恢复；如果所属项目仍在回收站，卡片回到未分类，否则会不可见。
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

  /// 删卡并在同一事务里清理引用它的记录（同步表没有外键级联）。返回这些卡正文引用过的图片哈希，
  /// 由调用方在同一事务里交给 `reclaimAttachments` 判断是否已无人引用。
  private func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws -> Set<String> {
    let ids = "SELECT id FROM cards WHERE \(condition)"
    let bodies = try db.query("SELECT body FROM cards WHERE \(condition)", arguments) { $0.text(0) }
    let referenced = Set(bodies.flatMap(CueFormat.imageHashes(in:)))
    try db.run("UPDATE sendRecords SET cardID = NULL, modifiedAt = ? WHERE cardID IN (\(ids))", [Date.stamp] + arguments)
    try db.run("DELETE FROM cards WHERE \(condition)", arguments)
    return referenced
  }

  /// 删除候选图片中已无人引用的（`isImageReferenced`）：先删文件，成功后再删记录，
  /// 所以记录与文件始终配对；删不掉的文件保留记录并返回其哈希。
  /// 只看被删卡片引用过的图片，不做全表扫描：刚粘贴、正文尚未保存的图片不能被顺手回收。
  /// 不处理跨设备竞态：另一台设备可能刚好在引用同一哈希。
  private func reclaimAttachments(_ candidates: Set<String>) throws -> [String] {
    var failed: [String] = []
    for hash in candidates.sorted() where try !isImageReferenced(hash) {
      do { try files.remove(hash: hash) } catch {
        failed.append(hash)
        continue
      }
      try db.run("DELETE FROM attachments WHERE hash = ?", [hash])
    }
    return failed
  }

  /// 还有卡片正文（含回收站里的卡）或发送记录快照（一键重发要用）引用这张图片。
  func isImageReferenced(_ hash: String) throws -> Bool {
    try db.first(
      """
      SELECT 1 FROM cards WHERE instr(body, ?1) > 0
      UNION ALL SELECT 1 FROM sendRecords WHERE instr(content, ?1) > 0
      """, [CueFormat.imageMarkup(id: hash)]) { _ in true } != nil
  }

  /// 事务已提交后，把删不掉文件的哈希作为错误报告（永久删除本身已生效）。
  private func reportingFileFailures(_ body: () throws -> [String]) throws {
    let failed = try body()
    if !failed.isEmpty { throw CueStoreError.attachmentFilesNotRemoved(failed) }
  }

  private func requireContent(_ content: String) throws {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankTaskContent }
  }

  /// 项目顶层（灵感与任务共用一个手动顺序）最前面的排序键。
  private func firstTopKey(in project: UUID?) throws -> String? {
    try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID IS ? AND parentID IS NULL", [project]) { $0.textOrNil(0) } ?? nil
  }

  private func insertCard(_ body: String, project: UUID?, parent: UUID?, todo: Bool, sortKey: String) throws -> Card {
    let now = Date.stamp
    let card = Card(
      id: UUID(), projectID: project, body: body, isPinned: false, variableValues: [:], conflictOf: nil, sortKey: sortKey,
      deletedAt: nil, createdAt: now, modifiedAt: now, parentID: parent, todoAt: todo ? now : nil)
    try insert(card)
    try registerImages(in: body)
    return card
  }

  /// 下级按原顺序提到 `card` 的位置（挂到它的上级下、排在它之后）：去掉要做、进回收站时用。
  private func liftChildren(of card: Card, at now: Date) throws {
    let children = try db.query("SELECT id FROM cards WHERE parentID = ? ORDER BY sortKey, id", [card.id]) { $0.uuid(0) }
    guard !children.isEmpty else { return }
    let link = CardLinks.Link(parent: card.parentID, project: card.projectID, isTask: card.isTask)
    let upper = try db.first(
      "SELECT MIN(sortKey) FROM cards WHERE (\(Self.siblingScope(link))) AND sortKey > ?", [card.parentID ?? card.projectID, card.sortKey]
    ) { $0.textOrNil(0) } ?? nil
    var lower = card.sortKey
    for child in children {
      let key = SortKey.between(lower, upper) ?? SortKey.after(lower)
      try db.run("UPDATE cards SET parentID = ?, sortKey = ?, modifiedAt = ? WHERE id = ?", [card.parentID, key, now, child])
      lower = key
    }
  }

  /// 同级的范围：同一上级下，或同一项目的顶层。
  private static func siblingScope(_ link: CardLinks.Link) -> String {
    link.parent == nil ? "parentID IS NULL AND projectID IS ?" : "parentID = ?"
  }

  private static func idList(_ ids: [UUID]) -> String {
    "[" + ids.map { "\"\($0.uuidString.lowercased())\"" }.joined(separator: ",") + "]"
  }
}

// MARK: 冲突副本

extension CueStore {
  /// 待用户处理的正文冲突：原卡与副本都还在的卡对，最近产生的在前。
  public func conflicts() throws -> [CardConflict] {
    try select(
      Card.self,
      where: "conflictOf IS NOT NULL AND deletedAt IS NULL AND conflictOf IN (SELECT id FROM cards)",
      orderBy: "modifiedAt DESC, id"
    ).compactMap { copy in
      try copy.conflictOf.flatMap { try find(Card.self, $0) }.map { CardConflict(original: $0, copy: copy) }
    }
  }

  /// 选定保留的版本并删除副本。原卡已不存在时，副本是唯一的版本：转为普通卡，不删除。
  public func resolveConflict(copy id: UUID, keep choice: ConflictChoice) throws {
    try reportingFileFailures {
      try write {
        guard let copy = try find(Card.self, id), let originalID = copy.conflictOf else {
          throw CueStoreError.notAConflictCopy
        }
        guard var original = try find(Card.self, originalID) else {
          try db.run("UPDATE cards SET conflictOf = NULL, modifiedAt = ? WHERE id = ?", [Date.stamp, id])
          return []
        }
        if case .copy = choice {
          original.body = copy.body
          original.modifiedAt = Date.stamp
          try update(original)
        }
        return try reclaimAttachments(purgeCards(where: "id = ?", [id]))
      }
    }
  }
}

// MARK: 发送记录、附件、Pi 会话索引

extension CueStore {
  /// 记录一次投送或复制：内容快照、目标、时间。发给 Pi 会话的是任务时，任务在同一事务里关联到该会话、置为进行中
  /// （完成了的也重新打开；任务行据此显示会话状态）：执行投送的那台 Mac 记，请求从哪台设备发来都一样。灵感发出去不变成任务。
  @discardableResult
  /// `parts`：一并带上的灵感（同一条记录里记下关联，不另存正文）。
  public func recordSend(_ content: String, to target: SendTarget, card: UUID? = nil, parts: [UUID] = []) throws -> SendRecord {
    try write {
      let now = Date.stamp
      let record = SendRecord(
        id: UUID(), content: content, targetKind: target.kind, targetName: target.name,
        targetRef: target.ref, cardID: card, sentAt: now, modifiedAt: now, partIDs: parts)
      try insert(record)
      try registerImages(in: content)
      if let card, target.kind == .known(.piSession), let session = target.ref {
        // 灵感与任务都记下交给了哪个会话；任务另外进行中
        try db.run(
          """
          UPDATE cards SET piSessionID = ?1, modifiedAt = ?2,
            startedAt = CASE WHEN todoAt IS NOT NULL THEN COALESCE(startedAt, ?2) END,
            completedAt = CASE WHEN todoAt IS NOT NULL THEN NULL END
          WHERE id = ?3
          """, [session, now, card])
      }
      return record
    }
  }

  /// 插入或更新会话索引（本机，不同步）；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。
  /// 同一事务里把它写成这个会话的同步记录（见 `writePiHistory`），`host` 是这台 Mac。
  /// `transcript` 是同一次读会话文件得到的对话与摘要，在同一事务里写（见 `writePiTranscript`）。
  public func upsertPiSession(_ session: PiSession, checkpoint: Data? = nil, host: String, transcript: PiTranscript? = nil) throws {
    try upsertPiSessions([PiSessionUpsert(session: session, checkpoint: checkpoint, transcript: transcript)], host: host)
  }

  /// 一批会话索引在同一个事务里写（首次回填几千个文件时：一次提交、一次变更通知，界面不为每个文件重读重画）。
  public func upsertPiSessions(_ batch: [PiSessionUpsert], host: String) throws {
    let assignments = PiSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let placeholders = (PiSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
    try write {
      for item in batch {
        try writePiHistory(item.session, host: host)
        if let transcript = item.transcript { try applyTranscript(transcript) }
        try db.run(
          """
          INSERT INTO piSessions (\(PiSession.columns.joined(separator: ", ")), checkpoint) VALUES (\(placeholders))
          ON CONFLICT(id) DO UPDATE SET \(assignments),
            checkpoint = COALESCE(excluded.checkpoint, piSessions.checkpoint)
          """, item.session.bindings + [item.checkpoint])
      }
    }
  }

  /// 只留下这些会话文件的索引，其余（文件已删除、不再算会话的）删除，返回删掉的条数。
  /// 同时让已结束的记录与会话文件一一对应：删掉这台 Mac 上没有会话文件的已结束会话记录（文件被删的；从没落盘的，
  /// 如 `--no-session` 或没发过消息的），补写有会话文件却没有记录的。在线的不动。
  @discardableResult
  public func retainPiSessions(paths: Set<String>, host: String) throws -> Int {
    try write {
      let stale = try db.query("SELECT id, path FROM piSessions") { ($0.text(0), $0.text(1)) }.filter { !paths.contains($0.1) }
      for (id, _) in stale { try db.run("DELETE FROM piSessions WHERE id = ?", [id]) }
      try db.run(
        "DELETE FROM piSessionStates WHERE hostID = ? AND state = ? AND sessionID NOT IN (SELECT id FROM piSessions)",
        [host, PiWorkState.ended.rawValue])
      // 反过来，有会话文件却还没有记录的（如升级前建的索引）补写
      let unrecorded = try select(
        PiSession.self, where: "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = piSessions.id)")
      for session in unrecorded { try writePiHistory(session, host: host) }
      return stale.count
    }
  }

  /// 全部目录绑定（各台 Mac 的），按项目、Mac 名排。
  public func directoryBindings() throws -> [DirectoryBinding] {
    try select(DirectoryBinding.self, orderBy: "projectID, hostName, hostID")
  }

  /// 把这台 Mac 本机的目录绑定写成同步的目录绑定记录：有绑定的写（目录末段名或 Mac 名变了才改），没了的删；别的 Mac 的不动。
  public func publishDirectoryBindings(host: String, hostName: String) throws {
    try write {
      let local = try projectDirectories()
      let mine = Dictionary(
        uniqueKeysWithValues: try select(DirectoryBinding.self, where: "hostID = ?", [host]).map { ($0.projectID, $0) })
      let now = Date.stamp
      for (project, directory) in local {
        let folder = URL(filePath: directory, directoryHint: .isDirectory).lastPathComponent
        if let existing = mine[project] {
          guard existing.folder != folder || existing.hostName != hostName else { continue }
          try db.run(
            "UPDATE directoryBindings SET folder = ?, hostName = ?, modifiedAt = ? WHERE id = ?", [folder, hostName, now, existing.id])
        } else {
          _ = try insert(DirectoryBinding(
            id: DirectoryBinding.recordID(project: project, host: host), projectID: project, hostID: host, hostName: hostName,
            folder: folder, createdAt: now, modifiedAt: now))
        }
      }
      for (project, binding) in mine where local[project] == nil {
        try db.run("DELETE FROM directoryBindings WHERE id = ?", [binding.id])
      }
    }
  }

  /// 本机索引里的一个会话（会话文件路径与工作目录）。
  public func piSession(_ id: String) throws -> PiSession? { try find(PiSession.self, id) }

  /// 会话文件索引写成同步记录：没有记录时插入一条已结束的；已结束的记录更新名字、所在与最后活动时间（没变不写，
  /// 免得每次启动把几千条历史重新上传）；在线的不动（由状态写入方负责）。必须在写事务内调用。
  private func writePiHistory(_ session: PiSession, host: String) throws {
    let id = PiSessionState.recordID(sessionID: session.id)
    let cwd = URL(filePath: session.cwd, directoryHint: .isDirectory)
    let folder = session.cwd.isEmpty ? nil : cwd.lastPathComponent
    let title = session.title.isEmpty ? folder ?? "" : session.title
    let projectID = session.cwd.isEmpty ? nil : try project(containing: cwd)?.id
    let now = Date.stamp
    guard let existing = try find(PiSessionState.self, id) else {
      _ = try insert(PiSessionState(
        id: id, sessionID: session.id, hostID: host, title: title, projectID: projectID, state: .known(.ended), detail: nil,
        folder: folder, lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: session.lastActivityAt,
        busySince: nil, createdAt: now, modifiedAt: now))
      return
    }
    guard existing.state == .known(.ended) else { return }
    let since = max(existing.stateSince, session.lastActivityAt)
    guard existing.title != title || existing.folder != folder || existing.projectID != projectID || existing.stateSince != since
    else { return }
    try db.run(
      "UPDATE piSessionStates SET title = ?, folder = ?, projectID = ?, stateSince = ?, modifiedAt = ? WHERE id = ?",
      [title, folder, projectID, since, now, id])
  }
}

// MARK: 引用校验

extension CueStore {
  /// 卡片只能归属存在且未在回收站的项目（或不归属）。必须在写事务内调用，
  /// 与随后的写入之间没有别的写入可以插进来。失效时报错，不静默改成未分类。
  fileprivate func requireLiveProject(_ project: UUID?) throws {
    guard let project else { return }
    let live = try db.first("SELECT 1 FROM projects WHERE id = ? AND deletedAt IS NULL", [project]) { _ in true }
    guard live != nil else { throw CueStoreError.invalidProject }
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

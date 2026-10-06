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
        isPinned: false, goalCardID: nil, deletedAt: nil, createdAt: now, modifiedAt: now)
      try insert(project)
      return project
    }
  }

  /// 改名称、颜色、图标、置顶。删除状态、目标卡对调用方只读，各有专门的方法（编译期保证）。
  public func updateProject(_ id: UUID, _ edit: @Sendable (inout Project) -> Void) throws {
    try write {
      guard var project = try find(Project.self, id) else { throw CueStoreError.notFound }
      edit(&project)
      project.modifiedAt = Date.stamp
      try update(project)
    }
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
  /// 新卡片放在所在项目（nil = 未归档）的最前。项目必须存在且未在回收站，否则抛 `invalidProject`。
  public func createCard(in project: UUID?, body: String = "") throws -> Card {
    try write {
      try requireLiveProject(project)
      let first = try db.first("SELECT MIN(sortKey) FROM cards WHERE projectID IS ?", [project]) {
        $0.textOrNil(0)
      } ?? nil
      let now = Date.stamp
      let card = Card(
        id: UUID(), projectID: project, body: body, isPinned: false,
        variableValues: [:], conflictOf: nil, sortKey: SortKey.before(first), deletedAt: nil, createdAt: now,
        modifiedAt: now)
      try insert(card)
      try registerImages(in: body)
      return card
    }
  }

  /// 改正文、置顶、变量取值。归属项目、排序键、删除状态对调用方只读，各有专门的方法（编译期保证）。
  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
      try registerImages(in: card.body)
    }
  }

  /// 移到 `project`（nil = 未归档）里 `previous` 之后（nil = 最前）。项目必须存在且未在回收站，否则抛 `invalidProject`。
  public func moveCard(_ id: UUID, to project: UUID?, after previous: UUID?) throws {
    try write {
      try requireLiveProject(project)
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

// MARK: 任务

extension CueStore {
  /// 新任务放在未完成任务的最前。项目（可省略）必须存在且未在回收站，否则抛 `invalidProject`。
  public func createTask(_ content: String, in project: UUID? = nil) throws -> CueTask {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CueStoreError.blankTaskContent
    }
    return try write {
      try requireLiveProject(project)
      let first = try db.first("SELECT MIN(sortKey) FROM tasks WHERE completedAt IS NULL") {
        $0.textOrNil(0)
      } ?? nil
      let now = Date.stamp
      let task = CueTask(
        id: UUID(), content: content, projectID: project, sortKey: SortKey.before(first),
        startedAt: nil, completedAt: nil, piSessionID: nil, createdAt: now, modifiedAt: now)
      try insert(task)
      return task
    }
  }

  /// 改内容、状态（`status`）、所属项目、关联 Pi 会话。
  /// 改挂的项目必须存在且未在回收站，否则抛 `invalidProject`。
  public func updateTask(_ id: UUID, _ edit: @Sendable (inout CueTask) -> Void) throws {
    try write {
      guard var task = try find(CueTask.self, id) else { throw CueStoreError.notFound }
      let originalProject = task.projectID
      edit(&task)
      if task.projectID != originalProject { try requireLiveProject(task.projectID) }
      guard !task.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CueStoreError.blankTaskContent
      }
      task.modifiedAt = Date.stamp
      try update(task)
    }
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
  /// 记录一次投送或复制：内容快照、目标、时间。发给 Pi 会话且带任务时，任务在同一事务里关联到该会话
  /// （任务行据此显示会话状态）：执行投送的那台 Mac 记，请求从哪台设备发来都一样。
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
      try registerImages(in: content)
      // 交给 Pi 的任务关联到该会话、置为进行中（完成了的也重新打开）
      if let task, target.kind == .known(.piSession), let session = target.ref {
        try db.run(
          "UPDATE tasks SET piSessionID = ?, startedAt = COALESCE(startedAt, ?), completedAt = NULL, modifiedAt = ? WHERE id = ?",
          [session, now, now, task])
      }
      return record
    }
  }

  /// 插入或更新会话索引（本机，不同步）；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。
  /// 同一事务里把它写成这个会话的同步记录（见 `writePiHistory`），`host` 是这台 Mac。
  /// `transcript` 是同一次读会话文件得到的对话与摘要，在同一事务里写（见 `writePiTranscript`）。
  public func upsertPiSession(_ session: PiSession, checkpoint: Data? = nil, host: String, transcript: PiTranscript? = nil) throws {
    try write {
      try writePiHistory(session, host: host)
      if let transcript { try applyTranscript(transcript) }
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
  /// 卡片和任务只能归属存在且未在回收站的项目（或不归属）。必须在写事务内调用，
  /// 与随后的写入之间没有别的写入可以插进来。失效时报错，不静默改成未归档。
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

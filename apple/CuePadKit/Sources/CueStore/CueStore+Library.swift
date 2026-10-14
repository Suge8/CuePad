import CueText
import Foundation

// MARK: 项目

extension CueStore {
  public func createProject(
    name: String, color: String, icon: String? = nil
  ) throws -> Project {
    try Self.requireName(name)
    return try write {
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
      try Self.requireName(project.name)
      project.modifiedAt = Date.stamp
      try update(project)
    }
  }

  private static func requireName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CueStoreError.blankProjectName }
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
  /// 绑定项目的文件夹（nil = 解除）。目录因设备而异，不同步。会话归哪个项目写在会话记录上（写入时按绑定定），
  /// 所以绑定变了、同一个事务里把本机已有的会话（含历史）按新的绑定重新归：只改归属变了的，没变的不重写。
  public func setDirectory(_ directory: String?, for project: UUID) throws {
    try write {
      if let directory {
        try db.run(
          """
          INSERT INTO projectDirectories (projectID, directory) VALUES (?, ?)
          ON CONFLICT(projectID) DO UPDATE SET directory = excluded.directory
          """, [project, directory])
      } else {
        try db.run("DELETE FROM projectDirectories WHERE projectID = ?", [project])
      }
      try reassignSessions()
    }
  }

  /// 本机会话索引里的会话各按工作目录重算文件夹名（`folderName(ofWorkingDirectory:)`）：旧版本写下的临时目录的文件夹名在这里清掉，
  /// 规则变了也跟着变；只改变了的。必须在写事务内调用。
  private func refreshSessionFolders() throws {
    let now = Date.stamp
    let directories = try db.query("SELECT DISTINCT cwd FROM piSessions") { $0.text(0) }
    for cwd in directories {
      let folder = Self.folderName(ofWorkingDirectory: cwd)
      try db.run(
        "UPDATE piSessionStates SET folder = ?, modifiedAt = ? WHERE sessionID IN (SELECT id FROM piSessions WHERE cwd = ?) AND folder IS NOT ?",
        [folder, now, cwd, folder])
    }
  }

  /// 本机会话索引里的会话各按它的工作目录重新归项目（同一目录只算一次）。必须在写事务内调用。
  private func reassignSessions() throws {
    let directories = try db.query("SELECT DISTINCT cwd FROM piSessions") { $0.text(0) }
    let now = Date.stamp
    let bound = try boundDirectories()
    for cwd in directories {
      let project = cwd.isEmpty ? nil : Self.projectID(containing: URL(filePath: cwd, directoryHint: .isDirectory), in: bound)
      try db.run(
        """
        UPDATE piSessionStates SET projectID = ?, modifiedAt = ?
        WHERE sessionID IN (SELECT id FROM piSessions WHERE cwd = ?) AND projectID IS NOT ?
        """, [project, now, cwd, project])
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

  /// 新任务（要做的卡片）放在所在项目顶层的最前。正文不能为空，否则抛 `blankTaskContent`；多行的第一行是任务、其余成为它的提示词。
  public func createTask(_ body: String, in project: UUID?) throws -> Card {
    try requireContent(body)
    return try write {
      try requireLiveProject(project)
      return try splittingPrompt(insertCard(body, project: project, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: project))))
    }
  }

  /// 新步骤放在 `parent` 的下级最后，项目随它。上级不是任务抛 `invalidParent`，已在第 `Card.maxTaskDepth` 级抛 `taskTooDeep`。
  /// 上级原本是叶子时，它的草稿与会话移到这个新步骤上（这一步就是已经在做的那件事，`CardLinks` 的规则）。
  public func createTask(_ body: String, under parent: UUID) throws -> Card {
    try requireContent(body)
    return try write {
      guard let link = try link(of: parent), link.isTask else { throw CueStoreError.invalidParent }
      guard try ancestors(of: parent).count + 1 < Card.maxTaskDepth else { throw CueStoreError.taskTooDeep }
      let last = try db.first("SELECT MAX(sortKey) FROM cards WHERE parentID = ?", [parent]) { $0.textOrNil(0) } ?? nil
      let step = try splittingPrompt(insertCard(body, project: link.project, parent: parent, todo: true, sortKey: SortKey.after(last)))
      try settle(around: [parent])  // 叶子加了第一个步骤：它的草稿与会话移到这个步骤上
      return try find(Card.self, step.id) ?? step
    }
  }

  /// 刚建好的任务：正文多行时拆出提示词，返回拆过的任务。
  private func splittingPrompt(_ task: Card) throws -> Card {
    guard try Self.splitPrompt(db, task: task.id, at: task.modifiedAt) != nil else { return task }
    return try find(Card.self, task.id) ?? task
  }

  /// 任务下新写一条提示词（叶子的草稿），项目随任务。上级不是任务抛 `invalidParent`。可以是空的：
  /// 写一条时先建好再进编辑，离开时还是空白就删掉（`dropIfBlank`）。提示词只挂在叶子下（`promptHome`），一个叶子最多一条：
  /// 叶子已有草稿时不另建，空的就返回那一条，有字的接到它末尾（`fold`）。
  public func createCard(body: String, under parent: UUID) throws -> Card {
    try write {
      guard let link = try link(of: parent), link.isTask else { throw CueStoreError.invalidParent }
      let home = try promptHome(parent)
      guard let draft = try Self.draft(of: home, in: db) else {
        return try insertCard(body, project: link.project, parent: home, todo: false, sortKey: SortKey.after(lastSortKey(under: home)))
      }
      if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let extra = try insertCard(body, project: link.project, parent: home, todo: false, sortKey: SortKey.after(lastSortKey(under: home)))
        try Self.fold([extra.id], into: draft, in: db, at: Date.stamp)
      }
      return try find(Card.self, draft)!
    }
  }

  private func lastSortKey(under parent: UUID) throws -> String? {
    try db.first("SELECT MAX(sortKey) FROM cards WHERE parentID = ?", [parent]) { $0.textOrNil(0) } ?? nil
  }

  /// 提示词挂在哪个任务下：提示词只挂在叶子（没有步骤的任务）下，往有步骤的任务上挂的落到它的第一个没完成的步骤（没有就第一个步骤），
  /// 见 `CardLinks.home(of:)`。不拒绝而是改挂：远端收敛（`CardLinks.repairs`）与结构升级本来就这样处理，本机写入同一个结果，
  /// 界面不必为"挂在有步骤的任务上"另做一条出错的路。`task` 必须是任务。
  func promptHome(_ task: UUID) throws -> UUID { try CardLinks(db, around: [task]).home(of: task) }

  /// 叶子绑着的会话；没绑为 nil。
  private func session(of leaf: UUID) throws -> String? {
    try db.first("SELECT piSessionID FROM cards WHERE id = ?", [leaf]) { $0.textOrNil(0) } ?? nil
  }

  /// 叶子的草稿：它下面第一条提示词（不是资料的灵感）；没有为 nil。
  static func draft(of leaf: UUID, in db: SQLite) throws -> UUID? {
    try db.first(
      "SELECT id FROM cards WHERE parentID = ? AND todoAt IS NULL AND isPinned = 0 AND deletedAt IS NULL ORDER BY sortKey, id LIMIT 1", [leaf]
    ) { $0.uuid(0) }
  }

  /// 改正文、置顶、变量取值。归属、结构、状态、删除对调用方只读，各有专门的方法（编译期保证）。
  public func updateCard(_ id: UUID, _ edit: @Sendable (inout Card) -> Void) throws {
    try write {
      guard var card = try find(Card.self, id) else { throw CueStoreError.notFound }
      edit(&card)
      card.modifiedAt = Date.stamp
      try update(card)
      try registerImages(in: card.body)
      // 任务正文只有标题：写进来的多余的话（命令行、别的版本同步来又被改过的）同样拆成它的提示词
      if card.isTask { _ = try Self.splitPrompt(db, task: id, at: card.modifiedAt, carryingHandoff: false) }
    }
  }

  /// 设为任务 / 改回灵感。设为任务：成为待办的任务；多行的话第一行留作任务，其余成为它的第一条提示词（`CueLines.split`）。
  /// 改回：回到灵感（状态与会话关联清掉），它的下级按原顺序提到它的位置。已经是这个样子时什么都不做、返回 nil；
  /// 否则返回回执（`undo` 拨回）。
  @discardableResult
  public func setTodo(_ id: UUID, _ on: Bool) throws -> CardChange? {
    try write { try applyTodo(id, on) }
  }

  @discardableResult
  private func applyTodo(_ id: UUID, _ on: Bool) throws -> CardChange? {
    guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
    guard card.isTask != on else { return nil }
    let now = Date.stamp
    var prompt: UUID?, lifted: [UUID] = []
    if on {
      try db.run("UPDATE cards SET todoAt = ?1, startedAt = NULL, completedAt = NULL, modifiedAt = ?1 WHERE id = ?2", [now, id])
      prompt = try Self.splitPrompt(db, task: id, at: now)
    } else {
      lifted = try liftChildren(of: card, at: now)
      try db.run(
        "UPDATE cards SET todoAt = NULL, startedAt = NULL, completedAt = NULL, piSessionID = NULL, formerSessionIDs = NULL, modifiedAt = ? WHERE id = ?",
        [now, id])
    }
    // 步骤增减：上级的草稿、会话与提升上来的下级按叶子的规则放回去
    if let parent = card.parentID { try settle(around: [parent]) }
    return .todo(id: id, on: on, body: card.body, variableValues: card.variableValues, prompt: prompt, lifted: lifted)
  }

  /// 任务正文除标题外还有话时拆出来（`CueLines.split`）：其余成为叶子（有步骤的任务是它的 `home`）的草稿：排在它下级最前，叶子已有草稿时并进那一条，
  /// 带着任务的变量取值；`carryingHandoff`（设为任务：灵感原本交给过会话）时再带上会话，发给 Agent 的记录（发送记录、投送请求）跟到提示词上。
  /// 返回提示词的 id，没有可拆的为 nil。设为任务、新建任务与结构升级共用。
  static func splitPrompt(_ db: SQLite, task: UUID, at now: Date, carryingHandoff: Bool = true) throws -> UUID? {
    guard let body = try db.first("SELECT body FROM cards WHERE id = ?", [task], { $0.text(0) }) else { return nil }
    let (heading, prompt) = CueLines.split(body)
    guard let prompt else { return nil }
    let home = try CardLinks(db, around: [task]).home(of: task)
    let existing = try draft(of: home, in: db)
    let first = try db.first("SELECT MIN(sortKey) FROM cards WHERE parentID = ?", [home]) { $0.textOrNil(0) } ?? nil
    let promptID = UUID()
    try db.run(
      """
      INSERT INTO cards (id, projectID, body, isPinned, variableValues, sortKey, conflictOf, deletedAt, createdAt, modifiedAt,
        parentID, todoAt, startedAt, completedAt, piSessionID, archivedAt)
      SELECT ?1, projectID, ?2, 0, variableValues, ?3, NULL, NULL, createdAt, ?4, ?7, NULL, NULL, NULL, CASE WHEN ?6 THEN piSessionID END, archivedAt
      FROM cards WHERE id = ?5
      """, [promptID, prompt, SortKey.before(first), now, task, carryingHandoff ? 1 : 0, home])
    try db.run("UPDATE cards SET body = ?, variableValues = '{}', modifiedAt = ? WHERE id = ?", [heading, now, task])
    for table in carryingHandoff ? ["sendRecords", "deliveryRequests"] : [] {
      try db.run("UPDATE \(table) SET cardID = ?, modifiedAt = ? WHERE cardID = ?", [promptID, now, task])
    }
    // 叶子已有草稿（改标题时写进来多余的话）：并进它末尾，不另立一条
    guard let existing else { return promptID }
    try fold([promptID], into: existing, in: db, at: now)
    return existing
  }

  /// 归档：连同下级一起（已归档的保留原时刻）。
  public func archive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id], at: Date.stamp)
    }
  }

  /// 从归档取回：连同下级一起回到原处。
  public func unarchive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id], at: nil)
    }
  }

  /// 任务页"最近完成"的一键归档：已完成的顶层任务（及其下级）全部归档，返回归档了几条任务。
  /// 没做完的任务下已完成的步骤算在上级的进度里，不单独归档。
  public func archiveCompletedTasks() throws -> Int {
    try write {
      let done = try db.query(
        """
        SELECT t.id FROM cards t
        WHERE t.todoAt IS NOT NULL AND t.completedAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL
          AND (t.parentID IS NULL OR t.parentID NOT IN (SELECT id FROM cards WHERE todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL))
        """
      ) { $0.uuid(0) }
      try setArchived(done, at: Date.stamp)
      return done.count
    }
  }

  /// 这些卡片连同各自的下级一起归档或取回。
  private func setArchived(_ roots: [UUID], at time: Date?) throws {
    let now = Date.stamp
    try db.run(
      """
      UPDATE cards SET archivedAt = ?1, modifiedAt = ?2
      WHERE id IN (\(Self.subtree(from: "SELECT value FROM json_each(?3)"))) AND (archivedAt IS NULL) = (?1 IS NOT NULL)
      """, [time, now, Self.idList(roots)])
  }

  /// 改任务的状态：进行中记开始时间（已有的保留），完成记完成时间（保留开始时间）并连带没完成的下级任务，回到待办两个都清空。
  /// 只往下连带：步骤全做完，上级任务也不自动完成，完成一件事由用户说了算（进度只算步骤，见 `subtaskProgress`）。
  /// 灵感没有状态，抛 `notATask`。
  public func setStatus(_ id: UUID, _ status: TaskStatus) throws {
    try write { _ = try applyStatus(id, status) }
  }

  /// 把任务改成 `status`（必须在写事务内）；返回改后的状态。已经是它时不动。
  @discardableResult
  func applyStatus(_ id: UUID, _ status: TaskStatus) throws -> TaskStatus {
    guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
    guard let current = card.status else { throw CueStoreError.notATask }
    guard current != status else { return status }
    let now = Date.stamp
    switch status {
    case .todo: try db.run("UPDATE cards SET startedAt = NULL, completedAt = NULL, modifiedAt = ? WHERE id = ?", [now, id])
    case .inProgress:
      try db.run("UPDATE cards SET startedAt = COALESCE(startedAt, ?1), completedAt = NULL, modifiedAt = ?1 WHERE id = ?2", [now, id])
    case .done:
      try db.run(
        """
        UPDATE cards SET completedAt = ?1, modifiedAt = ?1
        WHERE completedAt IS NULL AND todoAt IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?2")))
        """, [now, id])
    }
    return status
  }

  /// 挪到 `slot` 里 `previous` 之后（nil = 最前），下级随它走、项目随新位置。卡片墙上的排序、换项目、缩进、
  /// 挂成步骤或提示词都是它。只能挂到任务下、不能挂到自己或自己的下级下（`invalidParent`），任务的子树超过 `Card.maxTaskDepth` 级任务抛 `taskTooDeep`。
  /// 灵感挂到任务下成为提示词，规则同 `createCard(body:under:)`：落在叶子（`promptHome`）、排在它的下级最后（给的 `previous` 作废）；
  /// 叶子已有草稿时，灵感的文字并进草稿末尾、灵感删掉，回执是 `.fold`；叶子绑了会话时不留提示词，灵感删掉，回执 `.handed` 带着它，
  /// 由界面接进会话的回复框。任务挂成步骤后，上级原来的草稿与会话按叶子的规则移到步骤上（`settle`）。
  /// 返回回执（`undo` 把它放回原来的位置：原来的上级或项目、原来的前一个同级；`.fold`、`.handed` 还原灵感与草稿原文）。
  @discardableResult
  public func moveCard(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
    try write { try handing(id, to: slot) ?? relocate(id, to: slot, after: previous) }
  }

  /// 灵感挂到绑了会话的叶子上：不留提示词，交出去（`.handed`）；别的情况为 nil，照常挪。
  /// 只在用户挪卡时判断：撤销与下级归位（`relocate`）是把卡放回原处，不交。
  private func handing(_ id: UUID, to slot: CardSlot) throws -> CardChange? {
    guard case .under(let parent) = slot, let card = try link(of: id), !card.isTask, !card.isPinned,
      try link(of: parent)?.isTask == true
    else { return nil }
    let home = try promptHome(parent)
    guard card.parent != home, let session = try session(of: home) else { return nil }
    return .handed(idea: try handOut(id), session: session)
  }

  @discardableResult
  private func relocate(_ id: UUID, to slot: CardSlot, after previous: UUID?) throws -> CardChange {
      guard let current = try link(of: id) else { throw CueStoreError.notFound }
      let origin = Self.siblingScope(current), originKey = current.parent ?? current.project
      let siblings = try db.query("SELECT id FROM cards WHERE (\(origin)) ORDER BY sortKey, id", [originKey]) { $0.uuid(0) }
      let before = siblings.firstIndex(of: id).flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
      let from: CardSlot = current.parent.map(CardSlot.under) ?? .top(project: current.project)
      let destination: CardLinks.Link
      var previous = previous
      var absorbing: UUID?
      switch slot {
      case .top(let project):
        try requireLiveProject(project)
        destination = CardLinks.Link(parent: nil, project: project, isTask: current.isTask)
      case .under(let parent):
        let above = try ancestors(of: parent)
        guard let target = try link(of: parent), target.isTask, parent != id, !above.contains(id) else {
          throw CueStoreError.invalidParent
        }
        if current.isTask, above.count + 1 + (try taskHeight(of: id)) > Card.maxTaskDepth { throw CueStoreError.taskTooDeep }
        if current.isTask || current.isPinned {
          destination = CardLinks.Link(parent: parent, project: target.project, isTask: current.isTask)
        } else {
          let home = try promptHome(parent)
          if home != parent { previous = try db.first("SELECT id FROM cards WHERE parentID = ? AND id != ? ORDER BY sortKey DESC, id DESC LIMIT 1", [home, id]) { $0.uuid(0) } }
          absorbing = try Self.draft(of: home, in: db).flatMap { $0 == id ? nil : $0 }
          destination = CardLinks.Link(parent: home, project: target.project, isTask: false)
        }
      }
      let now = Date.stamp
      if let draft = absorbing {
        guard let idea = try find(Card.self, id), let kept = try find(Card.self, draft) else { throw CueStoreError.notFound }
        try Self.fold([id], into: draft, in: db, at: now)
        return .fold(idea: idea, draft: draft, body: kept.body, variableValues: kept.variableValues)
      }
      try db.run("UPDATE cards SET parentID = ?, modifiedAt = ? WHERE id = ?", [destination.parent, now, id])
      if destination.project != current.project {
        try db.run(
          "UPDATE cards SET projectID = ?, modifiedAt = ? WHERE id IN (\(Self.subtree(from: "SELECT ?3")))", [destination.project, now, id])
      }
      try place(scope: Self.siblingScope(destination), [destination.parent ?? destination.project], id: id, after: previous)
      if current.isTask, let parent = destination.parent { try settle(around: [parent]) }
      return .move(id: id, from: from, after: before)
  }

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
        let lifted = try liftChildren(of: card, at: now)
        try db.run("UPDATE cards SET deletedAt = ?1, modifiedAt = ?1 WHERE id = ?2", [now, id])
        if let parent = card.parentID { try settle(around: [parent]) }
        return .trash(id: id, lifted: lifted)
      }
    }
  }

  /// 恢复；如果所属项目仍在回收站，卡片回到未分类，否则会不可见。
  public func restoreCard(_ id: UUID) throws {
    try write { try restoreRow(id) }
  }

  private func restoreRow(_ id: UUID) throws {
    try db.run(
      """
      UPDATE cards SET deletedAt = NULL, modifiedAt = ?,
        projectID = CASE WHEN projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL)
                         THEN NULL ELSE projectID END
      WHERE id = ?
      """, [Date.stamp, id])
    // 恢复回原来的叶子（或有步骤的任务）下的提示词，按叶子的规则放好
    if let parent = try find(Card.self, id)?.parentID { try settle(around: [parent]) }
  }

  /// 拨回一次改动（`setTodo`、`trashCard`、`moveCard` 的回执），整个拨回是一个事务：
  /// 设为任务拆出的提示词删掉、正文与变量取值合回；改回灵感后下级回到它下面；删除恢复、提上去的下级回到它下面；挪动放回原来的位置。
  /// 其间已经不在了的下级跳过，原来的前一个同级不在了就排到最前。
  public func undo(_ change: CardChange) throws { try undo([change]) }

  /// 一次拨回多个回执（批量删除的撤销），同一个事务，倒序拨回。
  public func undo(_ changes: [CardChange]) throws {
    try reportingFileFailures { try write {
      var orphaned: Set<String> = []
      for change in changes.reversed() { orphaned.formUnion(try undoRow(change)) }
      return try reclaimAttachments(orphaned)
    } }
  }

  /// 拨回一个回执（在调用方的事务里）；返回因此不再被引用的图片。
  private func undoRow(_ change: CardChange) throws -> Set<String> {
    var orphaned: Set<String> = []
    switch change {
    case .todo(let id, let on, let body, let variableValues, let prompt, let lifted):
      if let prompt {
        orphaned = try purgeCards(where: "id = ?", [prompt])
        if var card = try find(Card.self, id) {
          card.body = body
          card.variableValues = variableValues
          card.modifiedAt = Date.stamp
          try update(card)
        }
        try registerImages(in: body)
      }
      try applyTodo(id, !on)
      try adopt(lifted, by: id)
    case .trash(let id, let lifted):
      try restoreRow(id)
      try adopt(lifted, by: id)
    case .move(let id, let slot, let after):
      let survivor = try after.flatMap { try find(Card.self, $0)?.id }
      try relocate(id, to: slot, after: survivor)
    case .fold(let idea, let draft, let body, let variableValues):
      if var card = try find(Card.self, draft) {
        card.body = body
        card.variableValues = variableValues
        card.modifiedAt = Date.stamp
        try update(card)
      }
      try restoreCard(idea)
    case .handed(let idea, _):
      try restoreCard(idea)
    }
    return orphaned
  }

  /// 把删掉的整张卡原样放回（撤销并入草稿、接进回复框）。
  private func restoreCard(_ idea: Card) throws {
    var restored = idea
    restored.modifiedAt = Date.stamp
    try insert(restored, ignoringExisting: true)
    try registerImages(in: idea.body)
  }

  /// 把这些卡按顺序重新挂到 `parent` 下（已经不在的跳过）。
  private func adopt(_ children: [UUID], by parent: UUID) throws {
    var previous: UUID?
    for child in children where try link(of: child) != nil {
      try relocate(child, to: .under(parent), after: previous)
      previous = child
    }
  }

  /// 离开一条灵感（含提示词）的编辑时：还是空白（`Card.isBlank`）就不留下。任务、写了字或放了图的不动。
  /// 记灵感与写提示词都是先建一条空的再进编辑，这是它们共用的收尾。
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

  /// 删卡并在同一事务里清理引用它的记录（同步表没有外键级联）。返回这些卡正文引用过的图片哈希，
  /// 由调用方在同一事务里交给 `reclaimAttachments` 判断是否已无人引用。
  private func purgeCards(where condition: String, _ arguments: [any SQLBindable] = []) throws -> Set<String> {
    try Self.purgeCards(where: condition, arguments, in: db)
  }

  static func purgeCards(where condition: String, _ arguments: [any SQLBindable] = [], in db: SQLite) throws -> Set<String> {
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
  func reclaimAttachments(_ candidates: Set<String>) throws -> [String] {
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

  /// 对话里你的消息中带图片的行（只有你的消息引用图片）；`?1` 是图片引用或它的开头 `CueFormat.imagePrefix`。
  static let userImages = "role = '\(PiChatRole.user.rawValue)' AND instr(text, ?1) > 0"

  /// 还有卡片正文（含回收站里的卡）、发送记录快照（一键重发要用）、对话里你的消息或 Cue 页的对话引用这张图片，或有预览用着这份文件。
  func isImageReferenced(_ hash: String) throws -> Bool {
    try db.first(
      """
      SELECT 1 FROM cards WHERE instr(body, ?1) > 0
      UNION ALL SELECT 1 FROM sendRecords WHERE instr(content, ?1) > 0
      UNION ALL SELECT 1 FROM piMessages WHERE \(Self.userImages)
      UNION ALL SELECT 1 FROM cueMessages WHERE instr(text, ?1) > 0
      UNION ALL SELECT 1 FROM previews WHERE hash = ?2
      """, [CueFormat.imageMarkup(id: hash), hash]) { _ in true } != nil
  }

  /// 事务已提交后，把删不掉文件的哈希作为错误报告（永久删除本身已生效）。
  func reportingFileFailures(_ body: () throws -> [String]) throws {
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

  /// 下级（含已归档的）按原顺序提到 `card` 的位置（挂到它的上级下、排在它之后）：去掉要做、进回收站时用。返回被提的下级，`undo` 靠它放回去。
  @discardableResult
  private func liftChildren(of card: Card, at now: Date) throws -> [UUID] {
    let children = try db.query("SELECT id FROM cards WHERE parentID = ? ORDER BY sortKey, id", [card.id]) { $0.uuid(0) }
    guard !children.isEmpty else { return [] }
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
    return children
  }

  /// 同级的范围：同一上级下，或同一项目的顶层。
  private static func siblingScope(_ link: CardLinks.Link) -> String {
    link.parent == nil ? "parentID IS NULL AND projectID IS ?" : "parentID = ?"
  }

  static func idList(_ ids: some Sequence<UUID>) -> String {
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
  /// 记录一次投送或复制：内容快照、目标、时间。发送记录只记"内容"的投送——说给 Agent 的话、发到应用、复制；命令与设置（config、answer、end、stop、bind、command）不记。发给 Pi 会话时，灵感与任务都在同一事务里记下交给了哪个会话；任务置为进行中
  /// （完成了的也重新打开；任务行据此显示会话状态），提示词（任务下的灵感）连带它的任务也一样。执行投送的那台 Mac 记，
  /// 请求从哪台设备发来都一样。灵感发出去不变成任务。经投送请求送出的带上请求的 id 与来源（`delivery`、`origin`）。
  @discardableResult
  public func recordSend(
    _ content: String, to target: SendTarget, card: UUID? = nil, delivery: UUID? = nil, origin: Open<DeliveryOrigin>? = nil
  ) throws -> SendRecord {
    try write {
      let now = Date.stamp
      let record = SendRecord(
        id: UUID(), content: content, targetKind: target.kind, targetName: target.name,
        targetRef: target.ref, cardID: card, sentAt: now, modifiedAt: now, deliveryID: delivery, origin: origin)
      try insert(record)
      try registerImages(in: content)
      if let card, target.kind == .known(.piSession), let session = target.ref { try linkCardInTransaction(card, toSession: session, at: now) }
      return record
    }
  }

  /// `deliveries`（会话消息的 `PiChatMessage.deliveryID`）里哪些是 Cue 说的：按发送记录认，送出它的请求清理了也认得出。
  public func cueSentDeliveries(among deliveries: some Sequence<UUID>) throws -> Set<UUID> {
    Set(try db.query(
      "SELECT deliveryID FROM sendRecords WHERE origin = '\(DeliveryOrigin.cue.rawValue)' AND deliveryID IN (SELECT value FROM json_each(?))",
      [Self.idList(deliveries)]) { $0.uuid(0) })
  }

  /// 把灵感或任务关联到一个会话（任务进行中，提示词连带它的任务也一样），不写发送记录：
  /// 发给 Agent 的命令带着卡片时用（命令不是内容的投送，发送记录只记内容）。会话只记在叶子上（`promptHome`）；
  /// 一个叶子最多一个会话，一个会话可以绑好几个叶子。
  public func linkCard(_ card: UUID, toSession session: String) throws {
    try write { try linkCardInTransaction(card, toSession: session, at: Date.stamp) }
  }

  private func linkCardInTransaction(_ card: UUID, toSession session: String, at now: Date) throws {
    guard let link = try link(of: card) else { return }
    var targets = [card]
    if link.isTask {
      targets = [try promptHome(card)]
    } else if let parent = link.parent {
      targets.append(try promptHome(parent))
    }
    try db.run(
      """
      UPDATE cards SET \(Self.keepingFormerSession("?1")), piSessionID = ?1, modifiedAt = ?2,
        startedAt = CASE WHEN todoAt IS NOT NULL THEN COALESCE(startedAt, ?2) END,
        completedAt = CASE WHEN todoAt IS NOT NULL THEN NULL END
      WHERE id IN (\(targets.map { _ in "?" }.joined(separator: ", ")))
      """, [session, now] + targets)
  }

  /// 把会话绑到叶子任务 `task` 上（会话页的"绑定到任务"、任务的右键）：叶子是没有步骤的任务，有步骤的抛 `notALeaf`，不是任务抛 `notATask`。
  /// 叶子原来绑着的会话换成这个；同一个会话可以绑好几个叶子。任务置为进行中（完成了的重新打开）。
  /// 绑了会话的叶子不留提示词（话在会话里说）：有草稿时交出去（`handOut`）、返回它的正文，界面把它接进这个会话的回复框，不自动发。
  @discardableResult
  public func bindSession(_ sessionID: String, to task: UUID) throws -> String? {
    try write {
      guard let link = try link(of: task) else { throw CueStoreError.notFound }
      guard link.isTask else { throw CueStoreError.notATask }
      guard try promptHome(task) == task else { throw CueStoreError.notALeaf }
      try forgetLaunches(of: task)
      try linkCardInTransaction(task, toSession: sessionID, at: Date.stamp)
      try endUnusedSessions(of: task, cue: false)
      return try Self.draft(of: task, in: db).map { try handOut($0).body }
    }
  }

  /// 绑了会话的叶子不留提示词：这张卡删掉、整张交出去，正文由界面接进会话的回复框（`bindSession` 的草稿、`moveCard` 的 `.handed`）。
  /// 图片文件不回收：正文被界面接去，发出之前不能让文件没了。
  private func handOut(_ id: UUID) throws -> Card {
    guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
    _ = try purgeCards(where: "id = ?", [id])
    return card
  }

  /// 解开叶子任务 `task` 绑着的会话：任务状态不变，会话照常；会话没结束又没有别的叶子了，记录它的 Mac 给它另挂同名任务（`adoptSessions`）。
  public func unbindSession(from task: UUID) throws {
    try write {
      try forgetLaunches(of: task)
      try db.run("UPDATE cards SET piSessionID = NULL, modifiedAt = ? WHERE id = ? AND piSessionID IS NOT NULL", [Date.stamp, task])
    }
  }

  /// 用户亲手绑定、解绑是之后的一次交给：指向这个任务的开新会话请求不再认领它（`claimLaunchedCards` 只认最近一次），
  /// 否则那个会话的记录一写（或同步过来）就把它抢回去；它们也就不再算"正在开会话"（`launchingLeaves` 按请求带着的卡认）。
  /// 带着草稿的请求不必另管：绑定时草稿交出去（`handOut`），请求就指不到这个任务了。
  private func forgetLaunches(of task: UUID) throws {
    try db.run("UPDATE deliveryRequests SET cardID = NULL, modifiedAt = ? WHERE cardID = ? AND mode = 'start'", [Date.stamp, task])
  }

  /// 这个会话属于的叶子任务：正在用它的与以前用过它的（`formerSessionIDs`；没删除、没归档，含完成了的），先开始的在前；步骤带着上级。
  /// 正在用它的是 `piSessionID` 等于它的那几个。
  public func tasks(boundTo sessionID: String) throws -> [LeafTask] {
    try select(
      Card.self,
      where: """
        (piSessionID = ?1 OR EXISTS (SELECT 1 FROM json_each(cards.formerSessionIDs) WHERE value = ?1))
          AND todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL AND \(Self.isLeaf("cards"))
        """,
      [sessionID], orderBy: "startedAt, id"
    ).map { LeafTask(task: $0, parent: try $0.parentID.flatMap { try find(Card.self, $0) }) }
  }

  /// 能绑会话的叶子（没完成、没绑会话、没删除、没归档）：步骤带着上级一起给，界面写"上级 · 步骤"。顺序同 `tasks(in:_:)`
  /// （项目页的任务顺序：同级手动顺序，步骤紧跟上级）。`project` 是会话所在的项目，nil 是没归项目的。
  public func bindableTasks(in project: UUID?) throws -> [LeafTask] {
    let open = try tasks(in: project, .todo, .inProgress)
    let byID = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let leaves = try Set(db.query("SELECT id FROM cards c WHERE c.todoAt IS NOT NULL AND \(Self.isLeaf("c"))") { $0.uuid(0) })
    var result: [LeafTask] = []
    for task in open where task.piSessionID == nil && leaves.contains(task.id) {
      var parent = task.parentID.flatMap { byID[$0] }
      if parent == nil, let id = task.parentID { parent = try find(Card.self, id) }
      result.append(LeafTask(task: task, parent: parent))
    }
    return result
  }

  /// 表 `alias` 里的任务是叶子：没有（没删除的）步骤。
  static func isLeaf(_ alias: String) -> String {
    "NOT EXISTS (SELECT 1 FROM cards s WHERE s.parentID = \(alias).id AND s.todoAt IS NOT NULL AND s.deletedAt IS NULL)"
  }

  /// 插入或更新会话索引（本机，不同步）；`checkpoint` 为 nil 时保留已存的检查点，非 nil 时在同一事务里替换。
  /// 同一事务里把它写成这个会话的同步记录（见 `writePiHistory`），`host` 是这台 Mac。
  /// `transcript` 是同一次读会话文件得到的对话与摘要，在同一事务里写（见 `writePiTranscript`）。
  public func upsertPiSession(_ session: IndexedSession, checkpoint: Data? = nil, host: String, transcript: PiTranscript? = nil) throws {
    try upsertPiSessions([PiSessionUpsert(session: session, checkpoint: checkpoint, transcript: transcript)], host: host)
  }

  /// 一批会话索引在同一个事务里写（首次回填几千个文件时：一次提交、一次变更通知，界面不为每个文件重读重画）。
  public func upsertPiSessions(_ batch: [PiSessionUpsert], host: String) throws {
    let assignments = IndexedSession.columns.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
    let placeholders = (IndexedSession.columns + ["checkpoint"]).map { _ in "?" }.joined(separator: ", ")
    try write {
      let bound = try boundDirectories()
      for item in batch {
        try writePiHistory(item.session, host: host, bound: bound)
        if let transcript = item.transcript { try applyTranscript(transcript) }
        try db.run(
          """
          INSERT INTO piSessions (\(IndexedSession.columns.joined(separator: ", ")), checkpoint) VALUES (\(placeholders))
          ON CONFLICT(id) DO UPDATE SET \(assignments),
            checkpoint = COALESCE(excluded.checkpoint, piSessions.checkpoint)
          """, item.session.bindings + [item.checkpoint])
      }
    }
  }

  /// 只留下这些会话文件的索引，其余（文件已删除、不再算会话的）删除，返回删掉的条数。
  /// 同时让已结束（与终端里被打断）的记录与会话文件一一对应：删掉这台 Mac 上没有会话文件的这类记录（文件被删的；从没落盘的，
  /// 如 `--no-session` 或没发过消息的——这也是已经留下的这类历史记录的清理，每次启动一次），补写有会话文件却没有记录的。在线的不动；
  /// 歇着的托管会话同样要有会话文件，由 `PiStateRecorder.dropUnindexedHosted` 对账（它知道哪些是此刻在线的）。
  /// 一个会话文件只算一个会话：同一个文件还按文件名记过一条的（旧版本在文件头写好之前读到它，见 `PiHistoryUpdate.isSession`），
  /// 删掉按文件名的那条，它的已结束记录随之删掉。
  /// 每个 Agent 的索引各自对账自己的会话（`agent`），别家的不动。
  @discardableResult
  public func retainPiSessions(paths: Set<String>, agent: AgentKind, host: String) throws -> Int {
    try write {
      let indexed = try db.query("SELECT id, path FROM piSessions WHERE COALESCE(agent, 'pi') = ?", [agent.rawValue]) { ($0.text(0), $0.text(1)) }
      let shared = Dictionary(grouping: indexed, by: \.1).filter { $0.value.count > 1 }
      let orphans = shared.flatMap { path, rows in rows.filter { $0.0 == URL(filePath: path).deletingPathExtension().lastPathComponent } }
      let stale = indexed.filter { !paths.contains($0.1) } + orphans
      for (id, _) in stale { try db.run("DELETE FROM piSessions WHERE id = ?", [id]) }
      try dropSessionRecords(
        where: """
          hostID = ? AND (state = ? OR state = ? AND hosted IS NULL) AND COALESCE(agent, 'pi') = ? AND sessionID NOT IN (SELECT id FROM piSessions)
          """,
        [host, PiWorkState.ended.rawValue, PiWorkState.interrupted.rawValue, agent.rawValue])
      // 反过来，有会话文件却还没有记录的（如升级前建的索引）补写
      let unrecorded = try select(
        IndexedSession.self, where: "NOT EXISTS (SELECT 1 FROM piSessionStates s WHERE s.sessionID = piSessions.id)")
      let bound = try boundDirectories()
      for session in unrecorded { try writePiHistory(session, host: host, bound: bound) }
      try refreshSessionFolders()
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
  public func piSession(_ id: String) throws -> IndexedSession? { try find(IndexedSession.self, id) }

  /// 会话文件索引写成同步记录：没有记录时插入一条已结束的；已结束的记录更新名字、所在与最后活动时间（没变不写，
  /// 免得检查点作废、从头重读时把几千条历史重新上传）；在线的不动（由状态写入方负责）。必须在写事务内调用。
  /// 变没变在 SQL 里按库里存的精度比：读会话文件得到的时间带亚毫秒，库里是毫秒，在 Swift 里比几乎总是"变了"。
  private func writePiHistory(_ session: IndexedSession, host: String, bound: [BoundDirectory]) throws {
    let id = PiSessionState.recordID(sessionID: session.id)
    let cwd = URL(filePath: session.cwd, directoryHint: .isDirectory)
    let folder = Self.folderName(ofWorkingDirectory: session.cwd)
    let title = session.title.isEmpty ? (session.cwd.isEmpty ? "" : cwd.lastPathComponent) : session.title
    let projectID = session.cwd.isEmpty ? nil : Self.projectID(containing: cwd, in: bound)
    let now = Date.stamp
    guard let existing = try find(PiSessionState.self, id) else {
      _ = try insert(PiSessionState(
        id: id, sessionID: session.id, hostID: host, title: title, projectID: projectID, state: .known(.ended), detail: nil,
        folder: folder, lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: session.lastActivityAt,
        busySince: nil, createdAt: now, modifiedAt: now, agent: .known(session.agent)))
      return
    }
    guard existing.state == .known(.ended) else { return }
    try followTitle(of: session.id, to: title)
    try db.run(
      """
      UPDATE piSessionStates SET title = ?1, folder = ?2, projectID = ?3, stateSince = MAX(stateSince, ?4), modifiedAt = ?5
      WHERE id = ?6 AND (title IS NOT ?1 OR folder IS NOT ?2 OR projectID IS NOT ?3 OR stateSince < ?4)
      """, [title, folder, projectID, session.lastActivityAt, now, id])
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
    scope: String, _ scopeArguments: [any SQLBindable] = [], id: UUID, after previous: UUID?
  ) throws {
    let siblings = try db.query(
      "SELECT id, sortKey FROM cards WHERE (\(scope)) AND id != ? ORDER BY sortKey, id",
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
      try db.run("UPDATE cards SET sortKey = ?, modifiedAt = ? WHERE id = ?", [key, now, rowID])
      guard db.changes > 0 else { throw CueStoreError.notFound }
    }
  }
}

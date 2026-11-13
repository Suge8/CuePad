import Foundation

extension CueStore {
  /// 连同下级一起（已归档的保留原时刻）。没做完的任务就此离开看板，没人再用的会话随之结束；做完了的在完成时已经结束过，之后又说话恢复的不动。
  /// 返回这次归档记下的时刻：撤销凭它只取回这一次归档的那些（`unarchive(_:archivedAt:)`）。
  @discardableResult
  public func archive(_ id: UUID) throws -> Date {
    try write {
      guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
      let now = Date.stamp
      try setArchived([id], at: now)
      if card.completedAt == nil { try endUnusedSessions(of: id, cue: false) }
      return now
    }
  }

  /// 撤销一次归档：只取回它和下级里归档时刻是 `time` 的。撤销可能隔了很久才来（系统撤销），其间另外归档的下级、取回后又归档的它自己都不动。
  public func unarchive(_ id: UUID, archivedAt time: Date) throws {
    try write {
      try db.run(
        "UPDATE cards SET archivedAt = NULL, modifiedAt = ?1 WHERE id IN (\(Self.subtree(from: "SELECT ?2"))) AND archivedAt = ?3", [Date.stamp, id, time])
    }
  }

  public func unarchive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id], at: nil)
    }
  }

  /// 已完成的顶层任务（及其下级）全部归档，置顶的留着，返回归档了几条。没做完的任务下已完成的子任务算在上级的进度里，不单独归档。
  /// 给了项目就只归档这个项目的（看板选了项目范围时，同 `TaskBoard.only`）。
  public func archiveCompletedTasks(in project: UUID? = nil) throws -> Int {
    try write {
      let done = try db.query(
        """
        SELECT t.id FROM cards t
        WHERE t.todoAt IS NOT NULL AND t.completedAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL AND t.isPinned = 0
          AND (t.parentID IS NULL OR t.parentID NOT IN (SELECT id FROM cards WHERE todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL))
          \(project == nil ? "" : "AND t.projectID = ?")
        """, project.map { [$0] } ?? []
      ) { $0.uuid(0) }
      try setArchived(done, at: Date.stamp)
      return done.count
    }
  }

  func setArchived(_ roots: [UUID], at time: Date?) throws {
    let now = Date.stamp
    if time != nil { try endCueSchedules(onTasksIn: Self.subtree(from: "SELECT value FROM json_each(?2)"), Self.idList(roots), at: now) }
    try db.run(
      """
      UPDATE cards SET archivedAt = ?1, modifiedAt = ?2
      WHERE id IN (\(Self.subtree(from: "SELECT value FROM json_each(?3)"))) AND (archivedAt IS NULL) = (?1 IS NOT NULL)
      """, [time, now, Self.idList(roots)])
  }

  /// 进行中在叶子与祖先上记开始时间（已有的保留）；完成记完成时间并连带没完成的下级、不再定时；回到待办连同没完成的下级清掉开始时间（已完成子任务保留，旧进展不重放）。完成的改成别的先经 `reopen`。只往下连带：子任务全做完，上级也不自动完成，完成一件事由用户说了算。灵感没有状态，抛 `notATask`。
  public func setStatus(_ id: UUID, _ status: TaskStatus) throws {
    if status == .done { _ = try completeTask(id) }
    else { try write { _ = try applyStatus(id, status) } }
  }

  /// 把任务改成 `status`（必须在写事务内）；返回改后库里的状态。已经是它时不动。
  @discardableResult
  func applyStatus(_ id: UUID, _ status: TaskStatus) throws -> TaskStatus {
    guard let card = try find(Card.self, id) else { throw CueStoreError.notFound }
    guard let current = card.status else { throw CueStoreError.notATask }
    guard current != status else { return status }
    let now = Date.stamp
    if current == .done { try reopen([id]) }
    switch status {
    case .todo:
      let descendants = try db.query("SELECT id FROM cards WHERE id IN (\(Self.subtree(from: "SELECT ?")))", [id]) { $0.uuid(0) }
      for task in descendants { _ = try reviseSessionBinding(task, explicit: true) }
      try db.run(
        """
        UPDATE cards SET startedAt = NULL, modifiedAt = ?1
        WHERE startedAt IS NOT NULL AND completedAt IS NULL AND id IN (\(Self.subtree(from: "SELECT ?2")))
        """, [now, id])
    case .inProgress: try beginTask(try homeLeaf(id), at: now)
    case .done:
      try db.run(
        """
        UPDATE cards SET completedAt = ?1, modifiedAt = ?1
        WHERE completedAt IS NULL AND todoAt IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?2")))
        """, [now, id])
      for ancestor in try ancestors(of: id) { try beginTask(ancestor, at: now) }
      try endCueSchedules(onTasksIn: Self.subtree(from: "SELECT ?2"), id, at: now)
    }
    return try find(Card.self, id)?.status ?? status
  }

  /// 子任务的新推进同时推进祖先；读取或同步回放不从已完成的旧子任务重新启动父任务。
  func beginTask(_ id: UUID, at now: Date) throws {
    let ids = [id] + (try ancestors(of: id))
    try db.run(
      "UPDATE cards SET startedAt = ?1, modifiedAt = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND todoAt IS NOT NULL AND completedAt IS NULL AND startedAt IS NULL",
      [now, Self.idList(ids)])
  }

}

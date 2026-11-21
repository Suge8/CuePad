import Foundation

extension CueStore {
  @discardableResult
  public func archive(_ id: UUID) throws -> CardChange {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      let now = Date.stamp
      return .archive(id: id, at: now, schedules: try setArchived([id], at: now))
    }
  }

  func unarchiveRow(_ id: UUID, archivedAt time: Date) throws {
    try db.run(
      "UPDATE cards SET archivedAt = NULL, modifiedAt = ?1 WHERE id IN (\(Self.subtree(from: "SELECT ?2"))) AND archivedAt = ?3", [Date.stamp, id, time])
  }

  public func unarchive(_ id: UUID) throws {
    try write {
      guard try find(Card.self, id) != nil else { throw CueStoreError.notFound }
      try setArchived([id], at: nil)
    }
  }

  public func archiveCompletedTasks(in project: UUID? = nil) throws -> Int {
    try write {
      let done = try db.query(
        """
        SELECT t.id FROM cards t
        WHERE \(Self.taskOnBoard("t")) AND t.completedAt IS NOT NULL AND t.isPinned = 0
          AND (t.parentID IS NULL OR t.parentID NOT IN (SELECT id FROM cards WHERE \(Self.taskOnBoard())))
          \(project == nil ? "" : "AND t.projectID = ?")
        """, project.map { [$0] } ?? []
      ) { $0.uuid(0) }
      try setArchived(done, at: Date.stamp)
      return done.count
    }
  }

  @discardableResult
  func setArchived(_ roots: [UUID], at time: Date?) throws -> [UUID] {
    let now = Date.stamp
    let ended = time == nil ? [] : try endCueSchedules(onTasksIn: Self.subtree(from: "SELECT value FROM json_each(?2)"), Self.idList(roots), at: now)
    try db.run(
      """
      UPDATE cards SET archivedAt = ?1, modifiedAt = ?2
      WHERE id IN (\(Self.subtree(from: "SELECT value FROM json_each(?3)"))) AND (archivedAt IS NULL) = (?1 IS NOT NULL)
      """, [time, now, Self.idList(roots)])
    return ended
  }

  public func setStatus(_ id: UUID, _ status: TaskStatus) throws {
    if status == .done { _ = try completeTask(id) }
    else { try write { _ = try applyStatus(id, status) } }
  }

  public func returnToTodo(_ id: UUID, to slot: CardSlot?, after previous: UUID?) throws {
    try write {
      try applyStatus(id, .todo)
      if let slot { try relocate(id, to: slot, after: previous) }
    }
  }

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

  func beginTask(_ id: UUID, at now: Date) throws {
    let ids = [id] + (try ancestors(of: id))
    try db.run(
      "UPDATE cards SET startedAt = ?1, modifiedAt = ?1 WHERE id IN (SELECT value FROM json_each(?2)) AND todoAt IS NOT NULL AND completedAt IS NULL AND startedAt IS NULL",
      [now, Self.idList(ids)])
  }

}

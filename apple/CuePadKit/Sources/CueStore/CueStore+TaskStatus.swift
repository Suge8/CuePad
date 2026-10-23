import Foundation

extension CueStore {
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

  /// 进展页看板"已完成"的一键归档：已完成的顶层任务（及其下级）全部归档，返回归档了几条任务。
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
      try setArchived(done, at: Date.stamp)
      return done.count
    }
  }

  /// 这些卡片连同各自的下级一起归档或取回。
  func setArchived(_ roots: [UUID], at time: Date?) throws {
    let now = Date.stamp
    try db.run(
      """
      UPDATE cards SET archivedAt = ?1, modifiedAt = ?2
      WHERE id IN (\(Self.subtree(from: "SELECT value FROM json_each(?3)"))) AND (archivedAt IS NULL) = (?1 IS NOT NULL)
      """, [time, now, Self.idList(roots)])
  }

  /// 改任务的状态：进行中在叶子上记开始时间（有子任务的记在此刻该做的那一步 `homeLeaf`，上级从子任务推出；已有的保留），完成记完成时间（保留开始时间）并连带没完成的下级任务，回到待办连同没完成的下级清掉开始时间
  /// （做完过的子任务还在时它仍算开始过，见 `TaskStatus`）；
  /// 完成的改成别的先经 `reopen`（连同已完成的上级、取回归档）。
  /// 只往下连带：子任务全做完，上级任务也不自动完成，完成一件事由用户说了算（进度只算子任务，见 `subtaskProgress`）。
  /// 灵感没有状态，抛 `notATask`。
  public func setStatus(_ id: UUID, _ status: TaskStatus) throws {
    try write { _ = try applyStatus(id, status) }
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
      try db.run(
        """
        UPDATE cards SET startedAt = NULL, modifiedAt = ?1
        WHERE startedAt IS NOT NULL AND completedAt IS NULL AND id IN (\(Self.subtree(from: "SELECT ?2")))
        """, [now, id])
    case .inProgress: try db.run("UPDATE cards SET startedAt = ?1, modifiedAt = ?1 WHERE id = ?2 AND startedAt IS NULL", [now, try homeLeaf(id)])
    case .done:
      try db.run(
        """
        UPDATE cards SET completedAt = ?1, modifiedAt = ?1
        WHERE completedAt IS NULL AND todoAt IS NOT NULL AND id IN (\(Self.subtree(from: "SELECT ?2")))
        """, [now, id])
    }
    return try find(Card.self, id)?.status ?? status
  }
}

import Foundation

extension CueStore {
  public func adoptSession(_ sessionID: String) throws -> UUID {
    try write {
      if let owner = try sessionOwners([sessionID])[sessionID], owner.leaf.completedAt == nil { return owner.task.id }
      guard let session = try sessionState(sessionID) else { throw CueStoreError.notFound }
      let live = try session.projectID.flatMap { id in try db.first("SELECT 1 FROM projects WHERE id = ? AND deletedAt IS NULL", [id]) { _ in id } }
      let project = live ?? Project.defaultID
      let task = try insertCard("", project: project, parent: nil, todo: true, sortKey: SortKey.before(firstTopKey(in: project)))
      try db.run(
        "UPDATE cards SET piSessionID = ?1, startedAt = ?2, modifiedAt = ?2 WHERE id = ?3", [sessionID, Date.stamp, task.id])
      return task.id
    }
  }
}

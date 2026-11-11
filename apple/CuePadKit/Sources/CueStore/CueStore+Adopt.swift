import Foundation

extension CueStore {
  /// 看板上不归没做完的事的活会话（`isLoose`）第一次被当任务用（拖到已完成、完成、置顶、改名）：当场给它建一件顶层任务绑上，之后的动作照任务的走。从没当任务用过的会话不留卡：不预建、不回填。
  /// 正文为空——标题为空时显示会话名、随会话改名变，改过标题后以任务为准。已有没做完的任务绑着它（别的设备刚建过、同一下点了两次）就是那一件，不再建。
  /// 两台设备离线时同时建会多出一件，照常同步，不为它做确定性 id。
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

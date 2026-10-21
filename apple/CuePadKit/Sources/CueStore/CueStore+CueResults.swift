import Foundation

extension CueStore {
  /// 这几件做完的任务这一次做完时 Cue 点名的成果图（`finishTask` 写的那条结果的 `shots`），按任务。
  /// 结果与完成写在同一个事务里、不早于完成的时刻（`completedAt`），所以只认这一次完成之后的：改回没做完再做完、这次没点名的，
  /// 不拿上一次的图冒充；你自己点圈做完的没有结果，也就没有图。每件取最近的一条，没点名的不在其中。
  public func cueResultShots(of tasks: [Card]) throws -> [UUID: [CueShot]] {
    let since = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in task.completedAt.map { (task.id, $0) } })
    guard !since.isEmpty else { return [:] }
    let reports = try select(
      CueMessage.self, where: "author = 'cue' AND choices IS NULL AND askShots IS NOT NULL AND taskID IN (SELECT value FROM json_each(?))",
      [Self.idList(since.keys)], orderBy: "createdAt DESC, rowid DESC")
    var shots: [UUID: [CueShot]] = [:]
    for report in reports {
      guard let task = report.taskID, shots[task] == nil, let done = since[task], report.createdAt >= done else { continue }
      shots[task] = report.shots
    }
    return shots
  }
}

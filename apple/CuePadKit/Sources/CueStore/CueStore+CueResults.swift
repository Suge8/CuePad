import Foundation

extension CueStore {
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

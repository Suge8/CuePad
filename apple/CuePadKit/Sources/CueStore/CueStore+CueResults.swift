import Foundation

extension CueStore {
  /// 这几件任务做完时 Cue 点名的成果图（`finishTask` 写的那条结果的 `shots`），按任务：每件取最近的一条，没点名的不在其中。
  public func cueResultShots(of tasks: [UUID]) throws -> [UUID: [CueShot]] {
    guard !tasks.isEmpty else { return [:] }
    let reports = try select(
      CueMessage.self, where: "author = 'cue' AND choices IS NULL AND askShots IS NOT NULL AND taskID IN (SELECT value FROM json_each(?))",
      [Self.idList(tasks)], orderBy: "createdAt DESC, rowid DESC")
    var shots: [UUID: [CueShot]] = [:]
    for report in reports { if let task = report.taskID, shots[task] == nil { shots[task] = report.shots } }
    return shots
  }
}

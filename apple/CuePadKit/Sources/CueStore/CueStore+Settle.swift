import Foundation

/// 会话只在叶子上（`CardLinks` 的类型注释）：这条规则被打破后怎么收敛，本机写入与远端变更共用这一处。
extension CueStore {
  /// 任务 `tasks` 的步骤刚变过：按 `CardLinks.repairs` 把它们记着的会话放回该在的叶子上
  /// （叶子加了第一个步骤时，它的会话就是这样移到那个步骤上的）。
  func settle(around tasks: [UUID]) throws {
    guard !tasks.isEmpty else { return }
    try apply(try CardLinks(db, around: tasks).repairs(touching: Set(tasks)))
  }

  /// 把收敛结果写进库。修改时间至少比现有的晚一毫秒：刚收下的远端版本可能带着比本机时钟更晚的时间，改写要算作更新的版本。
  func apply(_ repairs: CardLinks.Repairs) throws {
    let now = Date.stamp
    for (id, link) in repairs.links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      try db.run(
        "UPDATE cards SET parentID = ?, projectID = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ?", [link.parent, link.project, now, id])
    }
    for (task, step) in repairs.sessions {
      if let step {
        try db.run(
          """
          UPDATE cards SET piSessionID = (SELECT piSessionID FROM cards WHERE id = ?1),
            startedAt = COALESCE(startedAt, (SELECT startedAt FROM cards WHERE id = ?1)), modifiedAt = MAX(modifiedAt + 1, ?3)
          WHERE id = ?2
          """, [task, step, now])
      }
      try db.run("UPDATE cards SET piSessionID = NULL, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ?", [now, task])
    }
  }
}

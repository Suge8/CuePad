import Foundation

/// 会话与开始时间只在叶子上（`CardLinks` 的类型注释）：这条规则被打破后怎么收敛，本机写入与远端变更共用这一处。
extension CueStore {
  /// 任务 `tasks` 的子任务刚变过：按 `CardLinks.repairs` 把它们记着的会话与开始时间放回该在的叶子上
  /// （叶子加了第一个子任务时，它的会话与开始就是这样移到那个子任务上的，上级从此从子任务推出开始）。
  func settle(around tasks: [UUID]) throws {
    guard !tasks.isEmpty else { return }
    try apply(try CardLinks(db, around: tasks).repairs(touching: Set(tasks)))
  }

  /// 把收敛结果写进库（版本比旧的大由库保证，见 `CueStore.guards`）。
  func apply(_ repairs: CardLinks.Repairs) throws {
    let now = Date.stamp
    for (id, link) in repairs.links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      try db.run(
        "UPDATE cards SET parentID = ?, projectID = ?, modifiedAt = ? WHERE id = ?", [link.parent, link.project, now, id])
    }
    for (task, step) in repairs.handoffs {
      if let step {
        try db.run(
          """
          UPDATE cards SET piSessionID = (SELECT piSessionID FROM cards WHERE id = ?1),
            startedAt = COALESCE(startedAt, (SELECT startedAt FROM cards WHERE id = ?1)), modifiedAt = ?3
          WHERE id = ?2
          """, [task, step, now])
      }
      try db.run("UPDATE cards SET piSessionID = NULL, startedAt = NULL, modifiedAt = ? WHERE id = ?", [now, task])
    }
  }
}

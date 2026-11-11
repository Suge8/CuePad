import Foundation

extension CueStore {
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
            sessionBindingRevision = (SELECT sessionBindingRevision FROM cards WHERE id = ?1),
            startedAt = COALESCE(startedAt, (SELECT startedAt FROM cards WHERE id = ?1)), modifiedAt = ?3
          WHERE id = ?2
          """, [task, step, now])
      }
      try db.run("UPDATE cards SET piSessionID = NULL, modifiedAt = ? WHERE id = ?", [now, task])
    }
  }
}

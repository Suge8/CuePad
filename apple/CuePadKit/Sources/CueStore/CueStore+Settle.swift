import Foundation

/// 提示词与会话只在叶子上（`CardLinks` 的类型注释）：这条规则被打破后怎么收敛，本机写入、远端变更与结构升级共用这一处。
extension CueStore {
  /// 任务 `tasks` 的步骤或提示词刚变过：按 `CardLinks.repairs` 把它们下面的提示词与会话放回该在的叶子上
  /// （叶子加了第一个步骤时，它的草稿与会话就是这样移到那个步骤上的）。
  func settle(around tasks: [UUID]) throws {
    guard !tasks.isEmpty else { return }
    try Self.apply(try CardLinks(db, around: tasks).repairs(touching: Set(tasks)), in: db, at: Date.stamp)
  }

  /// 把收敛结果写进库。修改时间至少比现有的晚一毫秒：刚收下的远端版本可能带着比本机时钟更晚的时间，改写要算作更新的版本。
  static func apply(_ repairs: CardLinks.Repairs, in db: SQLite, at now: Date) throws {
    for (id, link) in repairs.links.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      try db.run(
        "UPDATE cards SET parentID = ?, projectID = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ?", [link.parent, link.project, now, id])
    }
    for (keep, others) in repairs.merges.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      try fold(others, into: keep, in: db, at: now)
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

  /// 把这些提示词按顺序并进 `keep`：文字接在末尾、空行隔开（图片引用照接），变量取值合并（同名的留 `keep` 的），被并的卡删掉。
  /// 图片都还在 `keep` 的正文里，没有要回收的附件。
  static func fold(_ ids: [UUID], into keep: UUID, in db: SQLite, at now: Date) throws {
    let marks = ids.map { _ in "?" }.joined(separator: ", ")
    let select = "SELECT \(Card.columns.joined(separator: ", ")) FROM cards"
    guard let kept = try db.first("\(select) WHERE id = ?", [keep], { Card(row: $0) }) else { return }
    let absorbed = try db.query("\(select) WHERE id IN (\(marks))", ids) { Card(row: $0) }.sorted { lhs, rhs in
      ids.firstIndex(of: lhs.id)! < ids.firstIndex(of: rhs.id)!
    }
    let cards = [kept] + absorbed
    let body = mergedBody(cards.map(\.body))
    let values = cards.reduce(into: [String: String]()) { $0.merge($1.variableValues) { first, _ in first } }
    try db.run(
      "UPDATE cards SET body = ?, variableValues = ?, modifiedAt = MAX(modifiedAt + 1, ?) WHERE id = ?",
      [body, JSONColumn.encode(values), now, keep])
    _ = try purgeCards(where: "id IN (\(marks))", ids, in: db)
  }

  /// 几段正文接成一段：各段去掉首尾空白，空的略去，空行隔开。
  static func mergedBody(_ parts: [String]) -> String {
    parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }
}

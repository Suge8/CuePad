import CueText
import Foundation

extension CueStore {
  public func cards(in project: UUID) throws -> [Card] {
    try select(Card.self, where: "(\(Self.cardActive)) AND (\(Self.looseIdea)) AND projectID = ?", [project], orderBy: "sortKey, id")
  }

  public func trashedCards() throws -> [Card] {
    try select(Card.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func card(_ id: UUID) throws -> Card? { try find(Card.self, id) }

  public func archived() throws -> [Card] {
    try select(
      Card.self,
      where: """
        (\(Self.cardVisible)) AND archivedAt IS NOT NULL
        AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE archivedAt IS NOT NULL AND deletedAt IS NULL))
        """,
      orderBy: "archivedAt DESC, id")
  }

  public func handedSessions() throws -> [UUID: AgentHandoff] {
    let handOff = "r.cardID IS NOT NULL AND (r.mode = 'start' OR (r.targetRef IS NOT NULL AND r.mode IN (\(sqlList(DeliveryMode.toSession)))))"
      + " AND \(Self.latestHandoff("r"))"
    let rows = try db.query(
      """
      SELECT r.cardID, r.targetRef, NULL, 0 AS rank FROM deliveryRequests r WHERE \(handOff) AND r.mode != 'start' AND r.status IN (\(DeliveryStatus.openSQL))
      UNION ALL
      SELECT id, piSessionID, NULL, 1 FROM cards WHERE piSessionID IS NOT NULL AND deletedAt IS NULL
      UNION ALL
      SELECT r.cardID, r.targetRef, CASE WHEN r.mode = 'start' THEN r.content END, 2 FROM deliveryRequests r
      WHERE \(handOff) AND r.cardID NOT IN (SELECT id FROM cards WHERE piSessionID IS NOT NULL)
        AND (r.mode != 'start' OR r.status != '\(DeliveryStatus.failed.rawValue)')
      ORDER BY rank
      """
    ) { row in
      let launch = row.isNull(2) ? nil : LaunchRequest(stored: row.text(2))
      return (card: row.uuid(0), handoff: row.isNull(2) ? AgentHandoff.session(row.text(1)) : .launching(launch?.agent ?? .pi))
    }
    return Dictionary(rows.map { ($0.card, $0.handoff) }, uniquingKeysWith: { first, _ in first })
  }

  public func children(of parent: UUID) throws -> [Card] {
    try select(Card.self, where: "parentID = ? AND deletedAt IS NULL AND archivedAt IS NULL", [parent], orderBy: "sortKey, id")
  }

  public func tasks(_ statuses: TaskStatus...) throws -> [TaskGroup] {
    try taskGroups(Set(statuses))
  }

  public func tasks(in project: UUID, _ statuses: TaskStatus...) throws -> [Card] {
    try taskGroups(Set(statuses), project: project).flatMap(\.tasks)
  }

  private func taskGroups(_ wanted: Set<TaskStatus>, project: UUID? = nil) throws -> [TaskGroup] {
    let doneOnly = wanted == [.done]
    let tasks = try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE \(Self.taskOnBoard("t")) \(doneOnly ? " AND t.completedAt IS NOT NULL" : "") \(project == nil ? "" : " AND t.projectID = ?")
      ORDER BY \(Self.taskProjectOrder), \(doneOnly ? Self.recentlyDone : "t.sortKey, t.id")
      """, project.map { [$0] } ?? []
    ) { Card(row: $0) }
    var groups: [TaskGroup] = []
    for task in tasks {
      if groups.last?.projectID == task.projectID, !groups.isEmpty {
        groups[groups.count - 1].tasks.append(task)
      } else {
        groups.append(TaskGroup(projectID: task.projectID, tasks: [task]))
      }
    }
    return groups.compactMap { group in
      let ordered = doneOnly ? group.tasks : Self.preorder(group.tasks).filter { $0.status.map(wanted.contains) ?? false }
      return ordered.isEmpty ? nil : TaskGroup(projectID: group.projectID, tasks: ordered)
    }
  }

  private static func preorder(_ tasks: [Card]) -> [Card] {
    let ids = Set(tasks.map(\.id))
    var children: [UUID: [Card]] = [:]
    for task in tasks { if let parent = task.parentID, ids.contains(parent) { children[parent, default: []].append(task) } }
    var ordered: [Card] = []
    func visit(_ task: Card) {
      ordered.append(task)
      for child in children[task.id] ?? [] { visit(child) }
    }
    for task in tasks where task.parentID.map({ !ids.contains($0) }) ?? true { visit(task) }
    return ordered
  }

  private static let taskWithParent =
    "FROM cards t LEFT JOIN cards u ON u.id = t.parentID AND \(taskOnBoard("u"))"
  private static let topLevel = "(u.id IS NULL OR (t.completedAt IS NULL AND u.completedAt IS NOT NULL))"

  public func taskCounts() throws -> [UUID: TaskCounts] { try taskCounts(scope: "", []) }

  public func taskCounts(in project: UUID) throws -> TaskCounts {
    try taskCounts(scope: "AND t.projectID = ?", [project])[project] ?? .zero
  }

  private func taskCounts(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: TaskCounts] {
    // GROUP BY 写成 +t.projectID：不然 SQLite 为省排序沿按项目的卡片索引逐张翻全部卡片，而不走 cards_todoAt 只翻任务
    let rows = try db.query(
      """
      SELECT t.projectID, SUM(t.completedAt IS NULL AND began), SUM(t.completedAt IS NULL AND NOT began), SUM(t.completedAt IS NOT NULL)
      FROM (SELECT t.projectID, t.completedAt, t.startedAt IS NOT NULL AS began \(Self.taskWithParent)
      WHERE \(Self.taskOnBoard("t")) AND \(Self.topLevel) \(scope)) t
      GROUP BY +t.projectID
      """, arguments
    ) { (project: $0.uuid(0), counts: TaskCounts(inProgress: Int($0.int(1)), todo: Int($0.int(2)), done: Int($0.int(3)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.counts) })
  }

  public func tasksDone(since: Date? = nil, in project: UUID? = nil, limit: Int? = nil) throws -> [Card] {
    var scope = "", arguments: [any SQLBindable] = []
    if let since {
      scope += " AND t.completedAt >= ?"
      arguments.append(since)
    }
    if let project {
      scope += " AND t.projectID = ?"
      arguments.append(project)
    }
    return try db.query(
      """
      SELECT \(Card.selection(as: "t")) \(Self.taskWithParent)
      WHERE \(Self.taskOnBoard("t")) AND t.completedAt IS NOT NULL AND \(Self.topLevel)\(scope)
      ORDER BY \(Self.recentlyDone) LIMIT ?
      """, arguments + [limit ?? -1]
    ) { Card(row: $0) }
  }

  public func subtaskProgress() throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "", []) }

  public func subtaskProgress(of parents: some Sequence<UUID>) throws -> [UUID: TaskProgress] {
    try subtaskProgress(scope: "AND parentID IN (SELECT value FROM json_each(?))", [Self.idList(parents)])
  }

  public func subtaskProgress(in project: UUID) throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "AND projectID = ?", [project]) }

  private func subtaskProgress(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: TaskProgress] {
    try Self.subtaskProgress(scope: scope, arguments, in: db)
  }

  static func subtaskProgress(scope: String, _ arguments: [any SQLBindable], in db: SQLite) throws -> [UUID: TaskProgress] {
    let rows = try db.query(
      """
      SELECT parentID, COUNT(*), COUNT(completedAt),
        CAST(AVG(CASE WHEN completedAt > startedAt THEN completedAt - startedAt END) AS INTEGER) FROM cards
      WHERE parentID IS NOT NULL AND \(taskOnBoard()) \(scope)
      GROUP BY parentID
      """, arguments
    ) { (parent: $0.uuid(0), progress: TaskProgress(done: Int($0.int(2)), total: Int($0.int(1)), stepTime: $0.intOrNil(3).map { Double($0) / 1000 })) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.parent, $0.progress) })
  }
}

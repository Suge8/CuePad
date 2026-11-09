import CueText
import Foundation

extension CueStore {
  public func cards(in project: UUID) throws -> [Card] {
    try select(Card.self, where: "(\(Self.cardActive)) AND (\(Self.looseIdea)) AND projectID = ?", [project], orderBy: "sortKey, id")
  }

  /// 随项目删除的卡归在该项目名下，不在这里。
  public func trashedCards() throws -> [Card] {
    try select(Card.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func card(_ id: UUID) throws -> Card? { try find(Card.self, id) }

  /// 只列归档时的那一条，不列随它一起归档的下级。
  public func archived() throws -> [Card] {
    try select(
      Card.self,
      where: """
        (\(Self.cardVisible)) AND archivedAt IS NOT NULL
        AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE archivedAt IS NOT NULL AND deletedAt IS NULL))
        """,
      orderBy: "archivedAt DESC, id")
  }

  /// 执行过或认领过的读灵感与任务上记的会话；还没执行的读最近一条投送请求。开新会话的是“正在开”（开好后由 `claimLaunchedCards` 记到卡上；没开成的不算交给过，任务行重新给“开始”）。
  /// 在路上的最近一条发给已有会话的请求优先于卡上记的会话：手机重发后状态点跟着那个会话（发送中），不停在旧的回复上。开新会话的请求不抢：开好时由认领记到卡上。
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
      let launch = row.isNull(2) ? nil : PiLaunch(stored: row.text(2))
      return (card: row.uuid(0), handoff: row.isNull(2) ? AgentHandoff.session(row.text(1)) : .launching(launch?.opening ?? .pi))
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
      WHERE \(Self.visibleTask) \(doneOnly ? " AND t.completedAt IS NOT NULL" : "") \(project == nil ? "" : " AND t.projectID = ?")
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

  private static let liveTask = "u.deletedAt IS NULL AND u.archivedAt IS NULL AND u.todoAt IS NOT NULL"

  private static let taskWithParent =
    "FROM cards t LEFT JOIN projects p ON p.id = t.projectID LEFT JOIN cards u ON u.id = t.parentID AND \(liveTask)"
  private static let topLevel = "(u.id IS NULL OR (t.completedAt IS NULL AND u.completedAt IS NOT NULL))"

  /// 给用户看的任务数与完成数只有这一处定义。顶层是显示在顶层的任务：没有上级、上级不在（没到、在回收站、归档了），或自己没完成而上级已完成（看板上它在顶层）。
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
      WHERE \(Self.visibleTask) AND \(Self.topLevel) \(scope)) t
      GROUP BY +t.projectID
      """, arguments
    ) { (project: $0.uuid(0), counts: TaskCounts(inProgress: Int($0.int(1)), todo: Int($0.int(2)), done: Int($0.int(3)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.counts) })
  }

  /// 给用户看的“做完了哪些”只有这一处：任务看板的做完列、实时活动的“今天做完”、项目页的“已完成”。顶层与可见的口径同 `taskCounts`。
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
      WHERE \(Self.visibleTask) AND t.completedAt IS NOT NULL AND \(Self.topLevel)\(scope)
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
      WHERE parentID IS NOT NULL AND todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL \(scope)
      GROUP BY parentID
      """, arguments
    ) { (parent: $0.uuid(0), progress: TaskProgress(done: Int($0.int(2)), total: Int($0.int(1)), stepTime: $0.intOrNil(3).map { Double($0) / 1000 })) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.parent, $0.progress) })
  }

  public func lastSends(in project: UUID) throws -> [UUID: LastSend] {
    Dictionary(
      uniqueKeysWithValues: try db.query(
        """
        SELECT s.cardID, s.sentAt, s.targetKind, s.targetName, s.targetRef FROM sendRecords s
        WHERE s.cardID IN (SELECT id FROM cards WHERE (\(Self.cardVisible)) AND projectID = ?)
          AND s.id = (SELECT t.id FROM sendRecords t WHERE t.cardID = s.cardID ORDER BY t.sentAt DESC, t.id DESC LIMIT 1)
        """, [project]
      ) {
        (
          $0.uuid(0),
          LastSend(
            sentAt: $0.date(1),
            target: SendTarget(kind: Open(rawValue: $0.text(2)), name: $0.text(3), ref: $0.textOrNil(4)))
        )
      })
  }

  /// 只含关联了卡片的发送：只有这些目标才可能筛出卡片。
  /// `ref` 靠 SQLite 对单个 MAX 聚合的裸列语义取自最近一行。
  public func sendTargets() throws -> [SendTarget] {
    try db.query(
      """
      SELECT targetKind, targetName, targetRef, MAX(sentAt) FROM sendRecords
      WHERE cardID IS NOT NULL
      GROUP BY targetKind, targetName
      ORDER BY MAX(sentAt) DESC, targetKind, targetName
      """
    ) {
      SendTarget(kind: Open(rawValue: $0.text(0)), name: $0.text(1), ref: $0.textOrNil(2))
    }
  }
}

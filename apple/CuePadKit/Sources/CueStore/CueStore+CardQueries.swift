import CueText
import Foundation

extension CueStore {
  /// 某项目里可见的灵感（不含任务，也不含挂在任务下的），按手动顺序：卡片墙与 `card list` 列的就是它们。
  /// 任务见 `tasks(_:)`，挂在任务下的见 `children(of:)`。
  public func cards(in project: UUID) throws -> [Card] {
    try select(Card.self, where: "(\(Self.cardActive)) AND (\(Self.looseIdea)) AND projectID = ?", [project], orderBy: "sortKey, id")
  }

  /// 回收站里单独删除的卡片，最近删除的在前；随项目删除的卡归在该项目名下，不在这里。
  public func trashedCards() throws -> [Card] {
    try select(Card.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func card(_ id: UUID) throws -> Card? { try find(Card.self, id) }

  /// 归档的灵感与任务（只列归档时的那一条，不列随它一起归档的下级），最近归档的在前；回收站里的不列。
  public func archived() throws -> [Card] {
    try select(
      Card.self,
      where: """
        (\(Self.cardVisible)) AND archivedAt IS NOT NULL
        AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE archivedAt IS NOT NULL AND deletedAt IS NULL))
        """,
      orderBy: "archivedAt DESC, id")
  }

  /// 交给了 Agent 的哪里：执行过或认领过的读灵感与任务上记的会话；还没执行的读最近一条投送请求——发给已有会话的是它的目标，
  /// 开新会话的是"正在开"（开好后由 `claimLaunchedCards` 记到卡上；没开成的不算交给过，任务行重新给"开始"）。灵感与任务的行据此显示状态点（含"发送中""有新回复"）。
  /// 在路上的（还没执行完的）最近一条发给已有会话的请求优先于卡上记的会话：手机重发后状态点跟着那个会话（发送中），
  /// 不停在旧的回复上。开新会话的请求不抢：开好时由认领记到卡上（`claimLaunchedCards`）。
  public func handedSessions() throws -> [UUID: AgentHandoff] {
    let handOff = "r.cardID IS NOT NULL AND (r.mode = 'start' OR (r.targetRef IS NOT NULL AND r.mode IN (\(sqlList(DeliveryMode.toSession)))))"
      + " AND \(Self.latestHandoff("r"))"
    let rows = try db.query(
      """
      SELECT r.cardID, r.targetRef, 0, 0 AS rank FROM deliveryRequests r WHERE \(handOff) AND r.mode != 'start' AND r.status IN (\(DeliveryStatus.openSQL))
      UNION ALL
      SELECT id, piSessionID, 0, 1 FROM cards WHERE piSessionID IS NOT NULL AND deletedAt IS NULL
      UNION ALL
      SELECT r.cardID, r.targetRef, r.mode = 'start', 2 FROM deliveryRequests r
      WHERE \(handOff) AND r.cardID NOT IN (SELECT id FROM cards WHERE piSessionID IS NOT NULL)
        AND (r.mode != 'start' OR r.status != '\(DeliveryStatus.failed.rawValue)')
      ORDER BY rank
      """
    ) { (card: $0.uuid(0), handoff: $0.int(2) != 0 ? AgentHandoff.launching : .session($0.text(1))) }
    return Dictionary(rows.map { ($0.card, $0.handoff) }, uniquingKeysWith: { first, _ in first })
  }

  /// 一张任务的下级（步骤与挂在下面的灵感），按手动顺序；在回收站的不列。
  public func children(of parent: UUID) throws -> [Card] {
    try select(Card.self, where: "parentID = ? AND deletedAt IS NULL AND archivedAt IS NULL", [parent], orderBy: "sortKey, id")
  }

  /// 这几种状态的任务，按项目分组：项目顺序同 `projects()`。组内是整棵任务树的先序（同级按手动顺序，
  /// 步骤紧跟上级）再按状态筛：上级被筛掉的步骤就排在上级原来的位置。只要完成的时不按树，最近完成在前。
  /// 回收站里的任务与回收站项目的任务不列。
  public func tasks(_ statuses: TaskStatus...) throws -> [TaskGroup] {
    try taskGroups(Set(statuses))
  }

  /// 一个项目里这几种状态的任务，排法同 `tasks(_:)` 的一组：只读这个项目，页面不必读全库再过滤。
  public func tasks(in project: UUID, _ statuses: TaskStatus...) throws -> [Card] {
    try taskGroups(Set(statuses), project: project).flatMap(\.tasks)
  }

  private func taskGroups(_ wanted: Set<TaskStatus>, project: UUID? = nil) throws -> [TaskGroup] {
    let doneOnly = wanted == [.done]
    let tasks = try db.query(
      """
      SELECT \(Card.selection(as: "t")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE \(Self.visibleTask) \(doneOnly ? " AND t.completedAt IS NOT NULL" : "") \(project == nil ? "" : " AND t.projectID = ?")
      ORDER BY \(Self.taskProjectOrder), \(doneOnly ? "t.completedAt DESC, t.id" : "t.sortKey, t.id")
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

  /// 按手动顺序排好的一组任务的先序：上级不在这组里的当顶层。
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

  /// 可当上级的任务：列得出来的（没删除、没归档）要做卡片。上级不在这里的步骤当顶层，与 `tasks(_:)` 列出的一致。
  private static let liveTask = "u.deletedAt IS NULL AND u.archivedAt IS NULL AND u.todoAt IS NOT NULL"

  /// 任务（`t`）连着它的项目（`p`）与列得出来的上级（`u`）；顶层的条件见 `topLevel`。`taskCounts`、`startedTasks` 与 `tasksDone` 共用。
  private static let taskWithParent =
    "FROM cards t LEFT JOIN projects p ON p.id = t.projectID LEFT JOIN cards u ON u.id = t.parentID AND \(liveTask)"
  private static let topLevel = "(u.id IS NULL OR (t.completedAt IS NULL AND u.completedAt IS NOT NULL))"

  /// 各项目的顶层任务按状态的个数——给用户看的任务数与完成数只有这一处定义。顶层是显示在顶层的任务：
  /// 没有上级、上级不在（没到、在回收站、归档了），或自己没完成而上级已完成（看板上它在顶层）；步骤的进度见 `subtaskProgress`。
  /// 灵感不算；没有任务的项目不在结果里；回收站里的任务与回收站项目不算。
  public func taskCounts() throws -> [UUID: TaskCounts] { try taskCounts(scope: "", []) }

  /// 一个项目的顶层任务数，口径同 `taskCounts()`；没有任务为 `.zero`。
  public func taskCounts(in project: UUID) throws -> TaskCounts {
    try taskCounts(scope: "AND t.projectID = ?", [project])[project] ?? .zero
  }

  private func taskCounts(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: TaskCounts] {
    // GROUP BY 写成 +t.projectID：不然 SQLite 为省排序沿 cards_projectID_modifiedAt 逐张翻全部卡片，而不走 cards_todoAt 只翻任务
    let rows = try db.query(
      """
      SELECT t.projectID, SUM(t.completedAt IS NULL AND began), SUM(t.completedAt IS NULL AND NOT began), SUM(t.completedAt IS NOT NULL)
      FROM (SELECT t.projectID, t.completedAt, \(Card.startedSQL("t")) IS NOT NULL AS began \(Self.taskWithParent)
      WHERE \(Self.visibleTask) AND \(Self.topLevel) \(scope)) t
      GROUP BY +t.projectID
      """, arguments
    ) { (project: $0.uuid(0), counts: TaskCounts(inProgress: Int($0.int(1)), todo: Int($0.int(2)), done: Int($0.int(3)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.counts) })
  }

  /// 进行中的任务（开始过、没完成，`Card.startedAt`），最近开始的在前，同刻按项目顺序与手动顺序；回收站、归档的不列。
  public func startedTasks() throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.selection(as: "t")) AS began \(Self.taskWithParent)
      WHERE \(Self.visibleTask) AND t.completedAt IS NULL AND began IS NOT NULL
      ORDER BY began DESC, \(Self.taskProjectOrder), t.sortKey, t.id
      """
    ) { Card(row: $0) }
  }

  /// 做完的顶层任务，最近做完的在前——给用户看的"做完了哪些"只有这一处：任务看板的做完列与更早做完的、实时活动的"今天做完"、项目页的"已完成"。
  /// 顶层与可见的口径同 `taskCounts`（做完的步骤跟着上级，归档、回收站里的与回收站项目的不算）。
  /// `since` 只要这一刻以来做完的，`project` 只要这个项目的，`limit` 至多几条。
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
      ORDER BY t.completedAt DESC, t.id\(limit.map { " LIMIT \($0)" } ?? "")
      """, arguments
    ) { Card(row: $0) }
  }

  /// 每条任务的步骤完成了几个、一共几个：任务行的完成圈与"步骤 n/m"由它推出；没有步骤的不在结果里。
  /// 不带参数读全库；`of` 只读这几条任务的；`in` 只读一个项目里的（下级与上级同项目）。
  public func subtaskProgress() throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "", []) }

  public func subtaskProgress(of parents: some Sequence<UUID>) throws -> [UUID: TaskProgress] {
    try subtaskProgress(scope: "AND parentID IN (SELECT value FROM json_each(?))", [Self.idList(parents)])
  }

  public func subtaskProgress(in project: UUID) throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "AND projectID = ?", [project]) }

  private func subtaskProgress(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: TaskProgress] {
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

  /// 项目里可见卡片的最近一次发送（时间与目标）：卡片 id → `LastSend`；从未发送的卡不在结果里。
  /// 一次查询覆盖整个项目，界面据此判断"未发送"和工作集，不必逐卡查询。
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

  /// 发送过卡片的目标，按种类与名称去重，最近使用的在前（`ref` 取该目标最近一次的）。
  /// 只含关联了卡片的发送：这些目标才可能筛出卡片，供搜索的"发给某目标"下拉使用。
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

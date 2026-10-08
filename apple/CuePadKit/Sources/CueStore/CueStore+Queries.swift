import CueText
import Foundation

/// 卡片可见：自身未删除，且所属项目（如果有）未删除。
private let cardVisible = """
  deletedAt IS NULL AND (projectID IS NULL OR projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL))
  """

/// 在列表里：可见且没归档（归档的只在"归档"里，搜索照样搜得到）。
private let cardActive = "(\(cardVisible)) AND archivedAt IS NULL"

/// 散放的灵感：不是任务，也没挂在一个看得见的任务下（上级没到、在回收站的按散放看待）。
private let looseIdea = """
  todoAt IS NULL AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE deletedAt IS NULL AND todoAt IS NOT NULL))
  """

extension CueStore {
  /// 未删除的项目，按项目唯一的顺序（`projectOrder`）。所有项目列表与选择器都用它，界面不另排。
  public func projects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NULL", orderBy: Self.projectOrder("projects"))
  }

  /// 项目的顺序：置顶在前，其余按最近活动——项目自身、其下卡片（灵感与任务）的最近修改、其 Pi 会话最近的状态变化中最晚的——
  /// 由近到远。`alias` 是查询里项目表的名字。
  static func projectOrder(_ alias: String) -> String {
    """
    \(alias).isPinned DESC, MAX(\(alias).modifiedAt,
      COALESCE((SELECT MAX(modifiedAt) FROM cards WHERE projectID = \(alias).id), 0),
      COALESCE((SELECT MAX(stateSince) FROM piSessionStates WHERE projectID = \(alias).id), 0)) DESC, \(alias).id
    """
  }

  /// 回收站中的项目，最近删除的在前。
  public func trashedProjects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func project(_ id: UUID) throws -> Project? { try find(Project.self, id) }

  /// 工作目录（如 Pi 会话的 cwd）属于哪个项目：两边先换成唯一写法（`canonicalPath`），项目绑定的目录是该目录本身或其祖先，按路径分段比较
  /// （`/a/proj` 不会误配 `/a/project`）；多个命中取绑定目录最深的，同深度取项目列表里靠前的。
  /// 只看未删除的项目，依据本机的目录绑定（`setDirectory`）。界面与命令行共用这唯一一份规则。
  public func project(containing directory: URL) throws -> Project? {
    let target = Self.pathSegments(Self.canonicalPath(directory.path))
    let bound = try db.query(
      """
      SELECT p.id, d.directory FROM projectDirectories d JOIN projects p ON p.id = d.projectID
      WHERE p.deletedAt IS NULL ORDER BY \(Self.projectOrder("p"))
      """
    ) { (id: $0.uuid(0), segments: Self.pathSegments(Self.canonicalPath($0.text(1)))) }

    var best: (id: UUID, depth: Int)?
    for candidate in bound where !candidate.segments.isEmpty && target.starts(with: candidate.segments) {
      if best.map({ candidate.segments.count > $0.depth }) ?? true { best = (candidate.id, candidate.segments.count) }
    }
    return try best.flatMap { try find(Project.self, $0.id) }
  }

  private static func pathSegments(_ path: String) -> [Substring] { path.split(separator: "/") }

  /// 同一个目录的唯一写法：由文件系统解析（`realpath`）——符号链接（含 `/tmp` → `/private/tmp`）换成真实路径，
  /// 大小写换成磁盘上的（区分大小写的卷上写错大小写就是另一个、不存在的目录）。不存在的路径只做标准化。
  static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(filePath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// 某项目（nil = 未分类）里可见的灵感（不含任务，也不含挂在任务下的提示词），按手动顺序：卡片墙、未分类与 `card list` 列的就是它们。
  /// 任务见 `tasks(_:)`，提示词见 `children(of:)`。
  public func cards(in project: UUID?) throws -> [Card] {
    try select(Card.self, where: "(\(cardActive)) AND (\(looseIdea)) AND projectID IS ?", [project], orderBy: "sortKey, id")
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
        (\(cardVisible)) AND archivedAt IS NOT NULL
        AND (parentID IS NULL OR parentID NOT IN (SELECT id FROM cards WHERE archivedAt IS NOT NULL AND deletedAt IS NULL))
        """,
      orderBy: "archivedAt DESC, id")
  }

  /// 交给了 Agent 的哪里：执行过或认领过的读灵感与任务上记的会话；还没执行的读最近一条投送请求——发给已有会话的是它的目标，
  /// 开新会话的是"正在开"（开好后由 `claimLaunchedCards` 记到卡上）。灵感与任务的行据此显示状态点（含"发送中""有新回复"）。
  public func handedSessions() throws -> [UUID: AgentHandoff] {
    let modes = DeliveryMode.toSession.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    let rows = try db.query(
      """
      SELECT id, piSessionID, 0 FROM cards WHERE piSessionID IS NOT NULL AND deletedAt IS NULL
      UNION ALL
      SELECT r.cardID, r.targetRef, r.mode = 'start' FROM deliveryRequests r
      WHERE r.cardID IS NOT NULL AND (r.mode = 'start' OR (r.targetRef IS NOT NULL AND r.mode IN (\(modes))))
        AND r.createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = r.cardID)
        AND r.cardID NOT IN (SELECT id FROM cards WHERE piSessionID IS NOT NULL)
      """
    ) { (card: $0.uuid(0), handoff: $0.int(2) != 0 ? AgentHandoff.launching : .session($0.text(1))) }
    return Dictionary(rows.map { ($0.card, $0.handoff) }, uniquingKeysWith: { first, _ in first })
  }

  /// 一张任务的下级（子任务与提示词），按手动顺序；在回收站的不列。
  public func children(of parent: UUID) throws -> [Card] {
    try select(Card.self, where: "parentID = ? AND deletedAt IS NULL AND archivedAt IS NULL", [parent], orderBy: "sortKey, id")
  }

  /// 这几种状态的任务，按项目分组：项目顺序同 `projects()`，未分类的在最后。组内是整棵任务树的先序（同级按手动顺序，
  /// 子任务紧跟上级）再按状态筛：上级被筛掉的子任务就排在上级原来的位置。只要完成的时不按树，最近完成在前。
  /// 回收站里的任务与回收站项目的任务不列。
  public func tasks(_ statuses: TaskStatus...) throws -> [TaskGroup] {
    let wanted = Set(statuses)
    let doneOnly = wanted == [.done]
    let tasks = try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL AND (t.projectID IS NULL OR p.deletedAt IS NULL)
        \(doneOnly ? " AND t.completedAt IS NOT NULL" : "")
      ORDER BY t.projectID IS NULL, \(Self.projectOrder("p")), \(doneOnly ? "t.completedAt DESC, t.id" : "t.sortKey, t.id")
      """
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

  /// 按手动顺序排好的一组任务的先序：上级不在这组里的当顶层；环里的（远端并发、还没收敛）接在最后。
  private static func preorder(_ tasks: [Card]) -> [Card] {
    let ids = Set(tasks.map(\.id))
    var children: [UUID: [Card]] = [:]
    for task in tasks { if let parent = task.parentID, ids.contains(parent) { children[parent, default: []].append(task) } }
    var ordered: [Card] = [], seen: Set<UUID> = []
    func visit(_ task: Card) {
      guard seen.insert(task.id).inserted else { return }
      ordered.append(task)
      for child in children[task.id] ?? [] { visit(child) }
    }
    for task in tasks where task.parentID.map({ !ids.contains($0) }) ?? true { visit(task) }
    for task in tasks { visit(task) }
    return ordered
  }

  /// 可当上级的任务：未删除的要做卡片。
  private static let liveTask = "u.deletedAt IS NULL AND u.todoAt IS NOT NULL"

  /// 各项目（nil = 未分类）的顶层任务按状态的个数——给用户看的任务数与完成数只有这一处定义。顶层是显示在顶层的任务：
  /// 没有上级、上级不在（没到、在回收站），或自己没完成而上级已完成（看板上它在顶层）；子任务的进度见 `childMarks`。
  /// 灵感（含提示词）不算；没有任务的项目不在结果里；回收站里的任务与回收站项目不算。
  public func taskCounts() throws -> [UUID?: TaskCounts] {
    let rows = try db.query(
      """
      SELECT t.projectID, SUM(t.completedAt IS NULL AND t.startedAt IS NOT NULL), SUM(t.completedAt IS NULL AND t.startedAt IS NULL),
        SUM(t.completedAt IS NOT NULL)
      FROM cards t LEFT JOIN projects p ON p.id = t.projectID LEFT JOIN cards u ON u.id = t.parentID AND \(Self.liveTask)
      WHERE t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL AND (t.projectID IS NULL OR p.deletedAt IS NULL)
        AND (u.id IS NULL OR (t.completedAt IS NULL AND u.completedAt IS NOT NULL))
      GROUP BY t.projectID
      """
    ) { (project: $0.uuidOrNil(0), counts: TaskCounts(inProgress: Int($0.int(1)), todo: Int($0.int(2)), done: Int($0.int(3)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.counts) })
  }

  /// 各上级任务的直接子任务（不含提示词）完成数与总数；没有子任务的不在结果里。
  /// 每条任务的直接下级，同级手动顺序：任务行的分段完成圈与"子任务 n/m"都由它推出，见 `ChildMark`。给了 `parent` 只读它的。
  /// 提示词（任务下的灵感）"已回复"：它最近一次交给 Pi 会话之后，那个会话歇下了（这一轮做完）或已结束——
  /// 会话状态从那之后才开始（`stateSince` 晚于发出时刻）。复制、发到应用不算交给 Agent。
  public func childMarks(of parent: UUID? = nil) throws -> [UUID: [ChildMark]] {
    let scope = parent == nil ? "" : "AND c.parentID = ?"
    let session = SendTargetKind.piSession.rawValue
    let rows = try db.query(
      """
      SELECT c.parentID, c.todoAt IS NOT NULL,
        CASE WHEN c.todoAt IS NOT NULL THEN c.completedAt IS NOT NULL
        ELSE EXISTS (
          SELECT 1 FROM sendRecords s JOIN piSessionStates p ON p.sessionID = s.targetRef
          WHERE s.cardID = c.id AND s.targetKind = '\(session)'
            AND s.sentAt = (SELECT MAX(q.sentAt) FROM sendRecords q WHERE q.cardID = c.id AND q.targetKind = '\(session)')
            AND p.state IN ('\(PiWorkState.settled.rawValue)', '\(PiWorkState.ended.rawValue)') AND p.stateSince > s.sentAt)
        END
      FROM cards c
      WHERE c.parentID IS NOT NULL AND c.deletedAt IS NULL AND c.archivedAt IS NULL \(scope)
      ORDER BY c.parentID, c.sortKey, c.id
      """, parent.map { [$0] } ?? []
    ) { (parent: $0.uuid(0), mark: ChildMark(isTask: $0.int(1) != 0, isDone: $0.int(2) != 0)) }
    return Dictionary(grouping: rows, by: \.parent).mapValues { $0.map(\.mark) }
  }

  /// 发送记录，最近的在前（同一毫秒按写入先后）。
  public func sendRecords() throws -> [SendRecord] {
    try select(SendRecord.self, orderBy: "sentAt DESC, rowid DESC")
  }

  /// 项目（nil = 未分类）里可见卡片的最近一次发送（时间与目标）：卡片 id → `LastSend`；从未发送的卡不在结果里。
  /// 一次查询覆盖整个项目，界面据此判断"未发送"和工作集，不必逐卡查询。
  public func lastSends(in project: UUID?) throws -> [UUID: LastSend] {
    Dictionary(
      uniqueKeysWithValues: try db.query(
        """
        SELECT s.cardID, s.sentAt, s.targetKind, s.targetName, s.targetRef FROM sendRecords s
        WHERE s.cardID IN (SELECT id FROM cards WHERE (\(cardVisible)) AND projectID IS ?)
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

  /// 会话的检查点（服务层存入的不透明字节）；会话不存在或尚未索引返回 nil。
  public func piCheckpoint(of session: String) throws -> Data? {
    try db.first("SELECT checkpoint FROM piSessions WHERE id = ?", [session]) { $0.blobOrNil(0) } ?? nil
  }

  public func piSessions() throws -> [PiSession] {
    try select(PiSession.self, orderBy: "lastActivityAt DESC, id")
  }

  // MARK: 汇总与搜索

  /// 每个活动项目（按手动顺序）和未分类（最后）的可见卡片数、最近修改时间。一次查询，侧栏不必读全部卡片。
  public func projectSummaries() throws -> [ProjectSummary] {
    let groups = try db.query(
      "SELECT projectID, SUM(\(looseIdea) AND archivedAt IS NULL), MAX(modifiedAt) FROM cards WHERE \(cardVisible) GROUP BY projectID"
    ) { (id: $0.uuidOrNil(0), count: Int($0.int(1)), last: $0.dateOrNil(2)) }
    let byProject = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    let owners: [UUID?] = try projects().map(\.id) + [nil]
    return owners.map {
      ProjectSummary(projectID: $0, cardCount: byProject[$0]?.count ?? 0, lastModifiedAt: byProject[$0]?.last)
    }
  }

  /// 卡片搜索：FTS5 索引匹配文字（可选），再按项目、图片、发送目标、修改时间筛选，最后排序分页。
  /// 文字按空白拆成多个词，全部命中才算命中，每个词是子串。卡片只按正文命中；项目名只用于
  /// `projects` 里单列的项目（每个词都在名字里）。按项目缩小卡片范围用 `projects` 筛选。
  /// 卡片按最近修改倒序（同刻按 id）；`totalCards` 是全部命中数。
  public func search(_ query: SearchQuery, limit: Int = 20, offset: Int = 0) throws -> SearchResults {
    let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
    let (condition, arguments) = cardCondition(query, terms: terms)
    let cards = try select(
      Card.self, where: condition, arguments, orderBy: "modifiedAt DESC, id", limit: limit, offset: offset)
    let total = try db.first("SELECT COUNT(*) FROM cards WHERE \(condition)", arguments) { Int($0.int(0)) } ?? 0

    var projects: [Project] = []
    if !terms.isEmpty, !query.hasCardFilters, offset == 0 {
      let named = terms.map { _ in "id IN (\(Self.hit("project")))" }.joined(separator: " AND ")
      projects = try select(
        Project.self, where: "\(named) AND (deletedAt IS NOT NULL) = ?",
        terms.map(Self.likePattern) + [query.inTrash], orderBy: Self.projectOrder("projects"), limit: 10)
    }
    return SearchResults(projects: projects, cards: cards, totalCards: total)
  }

  private static func hit(_ kind: String) -> String {
    "SELECT refID FROM searchIndex WHERE kind = '\(kind)' AND text LIKE ? ESCAPE '\\'"
  }

  private static func likePattern(_ text: String) -> String {
    "%\(text.replacing(/[\\%_]/) { "\\\($0.output)" })%"
  }

  private func cardCondition(_ query: SearchQuery, terms: [String]) -> (String, [any SQLBindable]) {
    var parts = [query.inTrash ? "NOT (\(cardVisible))" : "(\(cardVisible))"]
    var arguments: [any SQLBindable] = []

    for term in terms {
      parts.append("id IN (\(Self.hit("card")))")
      arguments.append(Self.likePattern(term))
    }
    if let projects = query.projects {
      let ids = projects.compactMap { $0 }
      var alternatives: [String] = []
      if !ids.isEmpty {
        alternatives.append("projectID IN (\(ids.map { _ in "?" }.joined(separator: ", ")))")
        arguments += ids
      }
      if projects.contains(UUID?.none) { alternatives.append("projectID IS NULL") }
      parts.append(alternatives.isEmpty ? "0" : "(\(alternatives.joined(separator: " OR ")))")
    }
    if let hasImages = query.hasImages {
      parts.append("instr(body, '\(CueFormat.imagePrefix)') \(hasImages ? ">" : "=") 0")
    }
    switch query.sent {
    case .any:
      break
    case .never:
      parts.append("id NOT IN (SELECT cardID FROM sendRecords WHERE cardID IS NOT NULL)")
    case .sent(let kind, let name):
      var subquery = "SELECT cardID FROM sendRecords WHERE cardID IS NOT NULL"
      if let kind {
        subquery += " AND targetKind = ?"
        arguments.append(kind.rawValue)
      }
      if let name {
        subquery += " AND targetName = ?"
        arguments.append(name)
      }
      parts.append("id IN (\(subquery))")
    }
    if let range = query.modifiedIn {
      parts.append("modifiedAt BETWEEN ? AND ?")
      arguments += [range.lowerBound, range.upperBound]
    }
    return (parts.joined(separator: " AND "), arguments)
  }
}

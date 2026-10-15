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

/// 列得出来的任务（`t` 是任务表，`p` 是它左连接的项目表）：要做、没删除、没归档，且所属项目（如果有）没删除。`tasks` 与 `taskCounts` 共用。
private let visibleTask = "t.todoAt IS NOT NULL AND t.deletedAt IS NULL AND t.archivedAt IS NULL AND (t.projectID IS NULL OR p.deletedAt IS NULL)"

/// 正文不是空白（与 `Card.isBlank` 同一条规则）。
private let notBlank = "TRIM(body, char(32, 9, 10, 13)) <> ''"

extension CueStore {
  /// 未删除的项目，按项目唯一的顺序（`projectOrder`）。所有项目列表与选择器都用它，界面不另排。
  public func projects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NULL", orderBy: Self.projectOrder("projects"))
  }

  /// 项目的顺序：置顶在前，其余按最近活动——项目自身、其下卡片（灵感与任务）的最近修改中最晚的——由近到远。
  /// Pi 会话的状态变化不算：不然 Agent 一变状态项目就换位置，侧栏在眼前跳、⌘1–9 对应的项目跟着变。`alias` 是查询里项目表的名字。
  static func projectOrder(_ alias: String) -> String {
    """
    \(alias).isPinned DESC, MAX(\(alias).modifiedAt,
      COALESCE((SELECT MAX(modifiedAt) FROM cards WHERE projectID = \(alias).id), 0)) DESC, \(alias).id
    """
  }

  /// 任务（`t`，左连接项目 `p`）按所属项目排：项目顺序同 `projectOrder`，未分类在后。项目还没同步到的任务（引用先于项目送达）
  /// 项目那几个键全是空值，再按 `t.projectID` 排：同一项目的任务总是连在一起，按项目分组时每个项目只成一组。
  static let taskProjectOrder = "t.projectID IS NULL, \(projectOrder("p")), t.projectID"

  /// 回收站里的条数：删除的项目加单独删除的卡片（`trashedProjects()` 与 `trashedCards()` 的个数之和），只数不读正文。
  public func trashCount() throws -> Int {
    try db.first(
      "SELECT (SELECT COUNT(*) FROM projects WHERE deletedAt IS NOT NULL) + (SELECT COUNT(*) FROM cards WHERE deletedAt IS NOT NULL)"
    ) { Int($0.int(0)) } ?? 0
  }

  /// 回收站里每个项目带进来的卡片数（项目被删后其下的卡片都看不见，含先前单独删除的）：一次查询，没有卡片的项目不在结果里。
  public func trashedProjectCardCounts() throws -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: try db.query(
      """
      SELECT projectID, COUNT(*) FROM cards
      WHERE NOT (\(cardVisible)) AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL) GROUP BY projectID
      """
    ) { ($0.uuid(0), Int($0.int(1))) })
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
    try Self.projectID(containing: directory, in: boundDirectories()).flatMap { try find(Project.self, $0) }
  }

  /// 项目绑定的目录（已换成唯一写法并按分段拆开），按项目顺序。批量归会话时读一次、对每个会话用 `projectID(containing:in:)`，
  /// 不为每个会话重读绑定表、重做 `realpath`。
  typealias BoundDirectory = (id: UUID, segments: [Substring])

  func boundDirectories() throws -> [BoundDirectory] {
    try db.query(
      """
      SELECT p.id, d.directory FROM projectDirectories d JOIN projects p ON p.id = d.projectID
      WHERE p.deletedAt IS NULL ORDER BY \(Self.projectOrder("p"))
      """
    ) { (id: $0.uuid(0), segments: Self.pathSegments(Self.canonicalPath($0.text(1)))) }
  }

  static func projectID(containing directory: URL, in bound: [BoundDirectory]) -> UUID? {
    let target = pathSegments(canonicalPath(directory.path))
    var best: (id: UUID, depth: Int)?
    for candidate in bound where !candidate.segments.isEmpty && target.starts(with: candidate.segments) {
      if best.map({ candidate.segments.count > $0.depth }) ?? true { best = (candidate.id, candidate.segments.count) }
    }
    return best?.id
  }

  private static func pathSegments(_ path: String) -> [Substring] { path.split(separator: "/") }

  /// 会话记录里的文件夹名（`PiSessionState.folder`）：工作目录的末段；临时目录（/tmp、/var/tmp、/var/folders，含 /private 写法，或路径里有
  /// TemporaryItems）与没有目录的没有。手机看不到路径，只据文件夹名建议绑定，临时目录不该进候选，所以由有路径的 Mac 在写入时认出——规则只此一处。
  public static func folderName(ofWorkingDirectory cwd: String) -> String? {
    guard !cwd.isEmpty, !isTemporary(cwd) else { return nil }
    return URL(filePath: cwd, directoryHint: .isDirectory).lastPathComponent
  }

  private static let temporaryRoots: [[Substring]] = [["tmp"], ["var", "tmp"], ["var", "folders"]]

  private static func isTemporary(_ path: String) -> Bool {
    var segments = pathSegments(URL(filePath: path).standardizedFileURL.path)
    if segments.first == "private" { segments.removeFirst() }
    return segments.contains("TemporaryItems") || temporaryRoots.contains { segments.starts(with: $0) }
  }

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
  /// 在路上的（还没执行完的）最近一条发给已有会话的请求优先于卡上记的会话：手机重发后状态点跟着那个会话（发送中），
  /// 不停在旧的回复上。开新会话的请求不抢：开好时由认领记到卡上（`claimLaunchedCards`）。
  public func handedSessions() throws -> [UUID: AgentHandoff] {
    let handOff = "r.cardID IS NOT NULL AND (r.mode = 'start' OR (r.targetRef IS NOT NULL AND r.mode IN (\(Self.toSessionModes))))"
      + " AND r.createdAt = (SELECT MAX(q.createdAt) FROM deliveryRequests q WHERE q.cardID = r.cardID)"
    let rows = try db.query(
      """
      SELECT r.cardID, r.targetRef, 0, 0 AS rank FROM deliveryRequests r WHERE \(handOff) AND r.mode != 'start' AND \(Self.openRequest)
      UNION ALL
      SELECT id, piSessionID, 0, 1 FROM cards WHERE piSessionID IS NOT NULL AND deletedAt IS NULL
      UNION ALL
      SELECT r.cardID, r.targetRef, r.mode = 'start', 2 FROM deliveryRequests r
      WHERE \(handOff) AND r.cardID NOT IN (SELECT id FROM cards WHERE piSessionID IS NOT NULL)
      ORDER BY rank
      """
    ) { (card: $0.uuid(0), handoff: $0.int(2) != 0 ? AgentHandoff.launching : .session($0.text(1))) }
    return Dictionary(rows.map { ($0.card, $0.handoff) }, uniquingKeysWith: { first, _ in first })
  }

  static let toSessionModes = DeliveryMode.toSession.map { "'\($0.rawValue)'" }.joined(separator: ", ")
  /// 还没执行完的请求（`r`）。
  private static let openRequest = "r.status IN ('\(DeliveryStatus.pending.rawValue)', '\(DeliveryStatus.executing.rawValue)')"

  /// 一张任务的下级（步骤与提示词），按手动顺序；在回收站的不列。
  public func children(of parent: UUID) throws -> [Card] {
    try select(Card.self, where: "parentID = ? AND deletedAt IS NULL AND archivedAt IS NULL", [parent], orderBy: "sortKey, id")
  }

  /// 这几种状态的任务，按项目分组：项目顺序同 `projects()`，未分类的在最后。组内是整棵任务树的先序（同级按手动顺序，
  /// 步骤紧跟上级）再按状态筛：上级被筛掉的步骤就排在上级原来的位置。只要完成的时不按树，最近完成在前。
  /// 回收站里的任务与回收站项目的任务不列。
  public func tasks(_ statuses: TaskStatus...) throws -> [TaskGroup] {
    try taskGroups(Set(statuses))
  }

  /// 一个项目（nil = 未分类）里这几种状态的任务，排法同 `tasks(_:)` 的一组：只读这个项目，页面不必读全库再过滤。
  public func tasks(in project: UUID?, _ statuses: TaskStatus...) throws -> [Card] {
    try taskGroups(Set(statuses), project: project).flatMap(\.tasks)
  }

  private func taskGroups(_ wanted: Set<TaskStatus>, project: UUID?? = nil) throws -> [TaskGroup] {
    let doneOnly = wanted == [.done]
    let tasks = try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) FROM cards t LEFT JOIN projects p ON p.id = t.projectID
      WHERE \(visibleTask) \(doneOnly ? " AND t.completedAt IS NOT NULL" : "") \(project == nil ? "" : " AND t.projectID IS ?")
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

  /// 可当上级的任务：列得出来的（没删除、没归档）要做卡片。上级不在这里的步骤当顶层，与 `tasks(_:)` 列出的一致。
  private static let liveTask = "u.deletedAt IS NULL AND u.archivedAt IS NULL AND u.todoAt IS NOT NULL"

  /// 任务（`t`）连着它的项目（`p`）与列得出来的上级（`u`）；顶层的条件见 `topLevel`。`taskCounts` 与 `startedTasks` 共用。
  private static let taskWithParent =
    "FROM cards t LEFT JOIN projects p ON p.id = t.projectID LEFT JOIN cards u ON u.id = t.parentID AND \(liveTask)"
  private static let topLevel = "(u.id IS NULL OR (t.completedAt IS NULL AND u.completedAt IS NOT NULL))"

  /// 各项目（nil = 未分类）的顶层任务按状态的个数——给用户看的任务数与完成数只有这一处定义。顶层是显示在顶层的任务：
  /// 没有上级、上级不在（没到、在回收站、归档了），或自己没完成而上级已完成（看板上它在顶层）；步骤的进度见 `subtaskProgress`。
  /// 灵感（含提示词）不算；没有任务的项目不在结果里；回收站里的任务与回收站项目不算。
  public func taskCounts() throws -> [UUID?: TaskCounts] { try taskCounts(scope: "", []) }

  /// 一个项目（nil = 未分类）的顶层任务数，口径同 `taskCounts()`；没有任务为 `.zero`。
  public func taskCounts(in project: UUID?) throws -> TaskCounts {
    try taskCounts(scope: "AND t.projectID IS ?", [project])[project] ?? .zero
  }

  private func taskCounts(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID?: TaskCounts] {
    // GROUP BY 写成 +t.projectID：不然 SQLite 为省排序沿 cards_projectID_modifiedAt 逐张翻全部卡片，而不走 cards_todoAt 只翻任务
    let rows = try db.query(
      """
      SELECT t.projectID, SUM(t.completedAt IS NULL AND t.startedAt IS NOT NULL), SUM(t.completedAt IS NULL AND t.startedAt IS NULL),
        SUM(t.completedAt IS NOT NULL)
      \(Self.taskWithParent)
      WHERE \(visibleTask) AND \(Self.topLevel) \(scope)
      GROUP BY +t.projectID
      """, arguments
    ) { (project: $0.uuidOrNil(0), counts: TaskCounts(inProgress: Int($0.int(1)), todo: Int($0.int(2)), done: Int($0.int(3)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0.counts) })
  }

  /// 进行中的任务（已开始、没完成），最近开始的在前，同刻按项目顺序与手动顺序；回收站、归档的不列。
  /// `topLevelOnly` 只要显示在顶层的（口径同 `taskCounts`：步骤跟着上级，上级也没完成时不单列）。
  public func startedTasks(topLevelOnly: Bool = false) throws -> [Card] {
    try db.query(
      """
      SELECT \(Card.columns.map { "t.\($0)" }.joined(separator: ", ")) \(Self.taskWithParent)
      WHERE \(visibleTask) AND t.startedAt IS NOT NULL AND t.completedAt IS NULL \(topLevelOnly ? "AND \(Self.topLevel)" : "")
      ORDER BY t.startedAt DESC, \(Self.taskProjectOrder), t.sortKey, t.id
      """
    ) { Card(row: $0) }
  }

  /// 每条任务的步骤完成了几个、一共几个：任务行的完成圈与"步骤 n/m"由它推出；没有步骤的不在结果里。
  /// 不带参数读全库；`of` 只读一条任务的；`in` 只读一个项目（nil = 未分类）里的（下级与上级同项目）。
  /// 提示词不在其中：提示词只表示发没发出去（见 `drafts()` 与 `handedSessions()`），不算任务的进度。
  public func subtaskProgress() throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "", []) }

  public func subtaskProgress(of parent: UUID) throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "AND parentID = ?", [parent]) }

  public func subtaskProgress(in project: UUID?) throws -> [UUID: TaskProgress] { try subtaskProgress(scope: "AND projectID IS ?", [project]) }

  func subtaskProgress(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: TaskProgress] {
    let rows = try db.query(
      """
      SELECT parentID, COUNT(*), COUNT(completedAt) FROM cards
      WHERE parentID IS NOT NULL AND todoAt IS NOT NULL AND deletedAt IS NULL AND archivedAt IS NULL \(scope)
      GROUP BY parentID
      """, arguments
    ) { (parent: $0.uuid(0), progress: TaskProgress(done: Int($0.int(2)), total: Int($0.int(1)))) }
    return Dictionary(uniqueKeysWithValues: rows.map { ($0.parent, $0.progress) })
  }

  /// 各叶子的草稿（同 `draft(of:)`：它下面第一条不是资料的提示词），按叶子取：任务行据此给"开始"。
  /// 不带参数读全库；`in` 只读一个项目（nil = 未分类）里的。归档、回收站里的不列。
  public func drafts() throws -> [UUID: Card] { try drafts(scope: "", []) }

  public func drafts(in project: UUID?) throws -> [UUID: Card] { try drafts(scope: "AND projectID IS ?", [project]) }

  private func drafts(scope: String, _ arguments: [any SQLBindable]) throws -> [UUID: Card] {
    let cards = try select(
      Card.self, where: "parentID IS NOT NULL AND todoAt IS NULL AND isPinned = 0 AND deletedAt IS NULL AND archivedAt IS NULL \(scope)", arguments,
      orderBy: "parentID, sortKey, id")
    return Dictionary(cards.map { ($0.parentID!, $0) }, uniquingKeysWith: { first, _ in first })
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

  /// 全部会话索引各从哪接着读（按会话文件路径）：检查点，与本机有没有它的对话。历史索引启动时一次读出，不逐个文件查。
  public func piIndexStarts() throws -> [String: IndexedSessionStart] {
    let rows = try db.query(
      "SELECT path, id, checkpoint, EXISTS (SELECT 1 FROM piMessages m WHERE m.sessionID = s.id) FROM piSessions s"
    ) { ($0.text(0), IndexedSessionStart(id: $0.text(1), checkpoint: $0.blobOrNil(2), hasMessages: $0.int(3) != 0)) }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }

  public func piSessions() throws -> [IndexedSession] {
    try select(IndexedSession.self, orderBy: "lastActivityAt DESC, id")
  }

  // MARK: 汇总与搜索

  /// 每个活动项目（按手动顺序）和未分类（最后）的灵感数：散放在列表里、不是空白的灵感。一次查询，不必读全部卡片。
  public func projectSummaries() throws -> [ProjectSummary] {
    let counts = Dictionary(uniqueKeysWithValues: try db.query(
      "SELECT projectID, COUNT(*) FROM cards WHERE (\(cardActive)) AND (\(looseIdea)) AND \(notBlank) GROUP BY projectID"
    ) { ($0.uuidOrNil(0), Int($0.int(1))) })
    let owners: [UUID?] = try projects().map(\.id) + [nil]
    return owners.map { ProjectSummary(projectID: $0, cardCount: counts[$0] ?? 0) }
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

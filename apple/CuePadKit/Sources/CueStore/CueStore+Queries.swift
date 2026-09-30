import Foundation

/// 卡片可见：自身未删除，且所属项目（如果有）未删除。
private let cardVisible = """
  deletedAt IS NULL AND (projectID IS NULL OR projectID IN (SELECT id FROM projects WHERE deletedAt IS NULL))
  """

extension CueStore {
  /// 未删除的项目，按手动顺序。
  public func projects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NULL", orderBy: "sortKey, id")
  }

  /// 回收站中的项目，最近删除的在前。
  public func trashedProjects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func project(_ id: UUID) throws -> Project? { try find(Project.self, id) }

  /// 某项目（nil = 未归档）里可见的卡片，按手动顺序。
  public func cards(in project: UUID?) throws -> [Card] {
    try select(Card.self, where: "(\(cardVisible)) AND projectID IS ?", [project], orderBy: "sortKey, id")
  }

  /// 全局收藏（可见的）。
  public func favoriteCards() throws -> [Card] {
    try select(Card.self, where: "(\(cardVisible)) AND isFavorite = 1", orderBy: "sortKey, id")
  }

  /// 回收站里单独删除的卡片，最近删除的在前；随项目删除的卡归在该项目名下，不在这里。
  public func trashedCards() throws -> [Card] {
    try select(Card.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func card(_ id: UUID) throws -> Card? { try find(Card.self, id) }

  /// 未完成任务，按手动顺序。
  public func tasks() throws -> [CueTask] {
    try select(CueTask.self, where: "completedAt IS NULL", orderBy: "sortKey, id")
  }

  /// 已完成任务，最近完成的在前。
  public func completedTasks() throws -> [CueTask] {
    try select(CueTask.self, where: "completedAt IS NOT NULL", orderBy: "completedAt DESC, id")
  }

  public func tags() throws -> [Tag] {
    try select(Tag.self, orderBy: "name, id")
  }

  /// 某卡片的标签，按名称。
  public func tags(of card: UUID) throws -> [Tag] {
    try select(
      Tag.self, where: "id IN (SELECT tagID FROM cardTags WHERE cardID = ?)", [card], orderBy: "name, id")
  }

  /// 发送记录，最近的在前。
  public func sendRecords() throws -> [SendRecord] {
    try select(SendRecord.self, orderBy: "sentAt DESC, id")
  }

  /// 项目（nil = 未归档）里可见卡片的最近一次发送（时间与目标）：卡片 id → `LastSend`；从未发送的卡不在结果里。
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
            target: SendTarget(kind: SendTargetKind(rawValue: $0.text(2)), name: $0.text(3), ref: $0.textOrNil(4)))
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
      SendTarget(kind: SendTargetKind(rawValue: $0.text(0)), name: $0.text(1), ref: $0.textOrNil(2))
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

  /// 每个活动项目（按手动顺序）和未归档（最后）的可见卡片数、最近修改时间。一次查询，侧栏不必读全部卡片。
  public func projectSummaries() throws -> [ProjectSummary] {
    let groups = try db.query(
      "SELECT projectID, COUNT(*), MAX(modifiedAt) FROM cards WHERE \(cardVisible) GROUP BY projectID"
    ) { (id: $0.uuidOrNil(0), count: Int($0.int(1)), last: $0.dateOrNil(2)) }
    let byProject = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    let owners: [UUID?] = try projects().map(\.id) + [nil]
    return owners.map {
      ProjectSummary(projectID: $0, cardCount: byProject[$0]?.count ?? 0, lastModifiedAt: byProject[$0]?.last)
    }
  }

  /// 卡片搜索：FTS5 索引匹配文字（可选），再按项目、图片、发送目标、修改时间筛选，最后排序分页。
  /// 文字按空白拆成多个词，全部命中才算命中，每个词是子串。卡片只按正文与标签命中；项目名只用于
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
        terms.map(Self.likePattern) + [query.inTrash], orderBy: "sortKey, id", limit: 10)
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
      parts.append(
        "(id IN (\(Self.hit("card"))) OR id IN (SELECT cardID FROM cardTags WHERE tagID IN (\(Self.hit("tag")))))")
      arguments += [Self.likePattern(term), Self.likePattern(term)]
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
      parts.append("instr(body, 'cuepad://img/') \(hasImages ? ">" : "=") 0")
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

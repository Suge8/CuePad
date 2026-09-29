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

  public func piSessions() throws -> [PiSession] {
    try select(PiSession.self, orderBy: "lastActivityAt DESC, id")
  }

  // MARK: 搜索

  /// 按项目名、卡片正文、标签名做子串搜索（大小写不敏感）；卡片可经标签命中。
  /// `inTrash` 为 true 时只搜回收站里的内容（含随项目进回收站的卡片）。
  public func search(_ term: String, inTrash: Bool = false) throws -> SearchResults {
    let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return SearchResults(projects: [], cards: []) }
    let escaped = term.replacing(/[\\%_]/) { "\\\($0.output)" }
    let pattern = "%\(escaped)%"
    let hit = { (kind: String) in
      "SELECT refID FROM searchIndex WHERE kind = '\(kind)' AND text LIKE ? ESCAPE '\\'"
    }

    let projects = try select(
      Project.self,
      where: "id IN (\(hit("project"))) AND (deletedAt IS NOT NULL) = ?",
      [pattern, inTrash], orderBy: "sortKey, id", limit: 10)
    let visibility = inTrash ? "NOT (\(cardVisible))" : cardVisible
    let cards = try select(
      Card.self,
      where: """
        (id IN (\(hit("card"))) OR id IN (SELECT cardID FROM cardTags WHERE tagID IN (\(hit("tag")))))
        AND (\(visibility))
        """,
      [pattern, pattern], orderBy: "modifiedAt DESC, id", limit: 20)
    return SearchResults(projects: projects, cards: cards)
  }
}

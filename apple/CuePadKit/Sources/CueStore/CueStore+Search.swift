import CueText
import Foundation

extension CueStore {
  /// 一次聚合，不读正文、附件或会话。
  public func projectSummaries() throws -> [ProjectSummary] {
    let summaries = Dictionary(uniqueKeysWithValues: try db.query(
      """
      SELECT projectID, SUM(CASE WHEN (\(Self.looseIdea)) AND \(Self.notBlank) THEN 1 ELSE 0 END), MAX(modifiedAt)
      FROM cards WHERE (\(Self.cardActive)) AND (todoAt IS NOT NULL OR \(Self.notBlank)) GROUP BY projectID
      """
    ) { ($0.uuid(0), (count: Int($0.int(1)), modified: $0.date(2))) })
    return try projects().map { project in
      let summary = summaries[project.id]
      return ProjectSummary(projectID: project.id, cardCount: summary?.count ?? 0,
                            modifiedAt: max(project.modifiedAt, summary?.modified ?? project.modifiedAt))
    }
  }

  /// 文字按空白拆成多个词，全部命中才算命中，每个词是子串。卡片只按正文命中；项目名只用于 `projects` 里单列的项目（`Project.nameMatch`）。按项目缩小卡片范围用 `projects` 筛选。
  public func search(_ query: SearchQuery, limit: Int = 20, offset: Int = 0) throws -> SearchResults {
    let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
    let (condition, arguments) = cardCondition(query, terms: terms)
    let cards = try select(
      Card.self, where: condition, arguments, orderBy: "modifiedAt DESC, id", limit: limit, offset: offset)
    let total = try db.first("SELECT COUNT(*) FROM cards WHERE \(condition)", arguments) { Int($0.int(0)) } ?? 0

    var projects: [Project] = []
    if !terms.isEmpty, !query.hasCardFilters, offset == 0 {
      let named = terms.map { Project.nameMatch($0, stored: "id IN (\(Self.hit("project")))") }
      projects = try select(
        Project.self, where: (named.map(\.sql) + ["(deletedAt IS NOT NULL) = ?"]).joined(separator: " AND "),
        zip(terms, named).flatMap { [Self.likePattern($0)] + $1.arguments } + [query.inTrash], orderBy: Self.projectOrder("projects"), limit: 10)
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
    var parts = [query.inTrash ? "NOT (\(Self.cardVisible))" : "(\(Self.cardVisible))"]
    var arguments: [any SQLBindable] = []

    for term in terms {
      parts.append("id IN (\(Self.hit("card")))")
      arguments.append(Self.likePattern(term))
    }
    if let projects = query.projects {
      parts.append("projectID IN (SELECT value FROM json_each(?))")
      arguments.append(Self.idList(projects))
    }
    if let hasAttachments = query.hasAttachments {
      parts.append("instr(body, '\(CueFormat.referencePrefix)') \(hasAttachments ? ">" : "=") 0")
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

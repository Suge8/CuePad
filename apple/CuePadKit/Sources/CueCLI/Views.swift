import CueStore
import CueText
import Foundation

typealias JSONObject = [String: any Sendable]

// MARK: 字段约定（改动须同步 `Schema` 的字段说明，测试会比对）

private func nullable<T: Sendable>(_ value: T?) -> any Sendable {
  guard let value else { return NSNull() }
  return value
}

private func uuid(_ id: UUID?) -> any Sendable { nullable(id?.uuidString.lowercased()) }

private func iso(_ date: Date?) -> any Sendable {
  nullable(date?.ISO8601Format(.init(includingFractionalSeconds: true)))
}

private func minutes(_ date: Date) -> String {
  date.formatted(
    .verbatim(
      "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
      timeZone: .current, calendar: .current))
}

/// 卡片标题（`CueSummary`），过长截断。
private func title(_ body: String) -> String {
  let title = CueSummary(body).title
  guard !title.isEmpty else { return "（空）" }
  return title.count > 60 ? title.prefix(60) + "…" : title
}

struct ProjectView {
  let project: Project
  let cardCount: Int
  let directory: String?

  var json: JSONObject {
    [
      "id": uuid(project.id), "name": project.name, "icon": nullable(project.icon), "color": project.color,
      "pinned": project.isPinned, "intro": nullable(project.intro), "directory": nullable(directory),
      "cardCount": cardCount, "createdAt": iso(project.createdAt), "modifiedAt": iso(project.modifiedAt),
    ]
  }

  var line: String {
    "\(project.id.shortID)  \(project.isPinned ? "★ " : "")\(project.name)  \(cardCount) 条灵感"
      + (directory.map { "  \($0)" } ?? "")
  }
}

struct CardView {
  let card: Card
  let project: String

  private static let mark: [TaskStatus: String] = [.todo: "[ ] ", .inProgress: "[~] ", .done: "[x] "]

  var json: JSONObject {
    [
      "id": uuid(card.id), "kind": card.isTask ? "task" : "idea", "status": nullable(card.status?.rawValue),
      "projectId": uuid(card.projectID), "project": project, "parentId": uuid(card.parentID), "body": card.body,
      "pinned": card.isPinned, "conflictOf": uuid(card.conflictOf), "startedAt": iso(card.startedAt), "completedAt": iso(card.completedAt),
      "archivedAt": iso(card.archivedAt), "deletedAt": iso(card.deletedAt), "createdAt": iso(card.createdAt), "modifiedAt": iso(card.modifiedAt),
    ]
  }

  var line: String {
    "\(card.status.flatMap { Self.mark[$0] } ?? "")\(card.id.shortID)  \(project)  \(card.isPinned ? "★ " : "")\(title(card.body))"
      + (card.parentID.map { "  ↳ \($0.shortID)" } ?? "")
  }

  /// `card show` 的文本：元信息，空行，正文原样。
  var detail: String {
    var rows = ["id: \(card.id.uuidString.lowercased())", "项目: \(project)"]
    if let status = card.status { rows.append("任务: \(status.rawValue)") }
    if let parent = card.parentID { rows.append("上级: \(parent.uuidString.lowercased())") }
    if card.isPinned { rows.append("置顶: 是") }
    if let original = card.conflictOf { rows.append("冲突副本，原来那条: \(original.uuidString.lowercased())") }
    if let deleted = card.deletedAt { rows.append("已删除: \(minutes(deleted))") }
    rows.append("修改: \(minutes(card.modifiedAt))")
    return rows.joined(separator: "\n") + "\n\n" + card.body
  }
}

// MARK: 从资料库取视图

extension Call {
  func projectNames() async throws -> [UUID: String] {
    let all = try await store.projects() + store.trashedProjects()
    return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
  }

  /// 项目的灵感数与绑定目录只在有项目要显示时才查。
  func projectViews(_ projects: [Project]) async throws -> [ProjectView] {
    guard !projects.isEmpty else { return [] }
    let counts = Dictionary(uniqueKeysWithValues: try await store.projectSummaries().map { ($0.projectID, $0.cardCount) })
    let directories = try await store.projectDirectories()
    return projects.map { ProjectView(project: $0, cardCount: counts[$0.id] ?? 0, directory: directories[$0.id]) }
  }

  func cardViews(_ cards: [Card]) async throws -> [CardView] {
    let names = try await projectNames()
    return cards.map { CardView(card: $0, project: names[$0.projectID] ?? "") }
  }

  func freshView(_ id: UUID) async throws -> CardView {
    guard let card = try await store.card(id) else { throw CLIError.notFound("\(id.uuidString.lowercased()) 已不存在") }
    return try await cardViews([card])[0]
  }
}

func listReply(_ lines: [String], json: [JSONObject]) -> Reply {
  Reply(text: lines.isEmpty ? "（无）\n" : lines.joined(separator: "\n") + "\n", json: json)
}

func reply(_ view: CardView) -> Reply { Reply(text: view.line + "\n", json: view.json) }

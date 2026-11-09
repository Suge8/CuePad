import CueStore
import CueText
import Foundation

typealias JSONObject = [String: any Sendable]

struct OutputFields<Value>: Sendable {
  let fields: [(String, @Sendable (Value) -> any Sendable)]

  func json(_ value: Value) -> JSONObject {
    Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1(value)) })
  }

  func description(_ name: String) -> String {
    (name.isEmpty ? "" : name + " ") + "{\(fields.map(\.0).joined(separator: ", "))}"
  }
}

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

private func title(_ body: String) -> String {
  let title = CueSummary.title(of: body)
  guard !title.isEmpty else { return "（空）" }
  return title.count > 60 ? title.prefix(60) + "…" : title
}

struct ProjectView {
  let project: Project
  let cardCount: Int
  let directory: String?

  static let fields = OutputFields<ProjectView>(fields: [
    ("id", { uuid($0.project.id) }), ("name", { $0.project.name }), ("intro", { nullable($0.project.intro) }),
    ("icon", { nullable($0.project.icon) }), ("color", { $0.project.color }), ("pinned", { $0.project.isPinned }),
    ("directory", { nullable($0.directory) }), ("cardCount", { $0.cardCount }),
    ("createdAt", { iso($0.project.createdAt) }), ("modifiedAt", { iso($0.project.modifiedAt) }),
  ])

  var json: JSONObject { Self.fields.json(self) }

  var line: String {
    "\(project.id.shortID)  \(project.isPinned ? "★ " : "")\(project.name)  \(cardCount) 条灵感"
      + (directory.map { "  \($0)" } ?? "")
  }
}

struct CardView {
  let card: Card
  let project: String

  private static let mark: [TaskStatus: String] = [.todo: "[ ] ", .inProgress: "[~] ", .done: "[x] "]

  static let fields = OutputFields<CardView>(fields: [
    ("id", { uuid($0.card.id) }), ("kind", { $0.card.isTask ? "task" : "idea" }), ("status", { nullable($0.card.status?.rawValue) }),
    ("projectId", { uuid($0.card.projectID) }), ("project", { $0.project }), ("parentId", { uuid($0.card.parentID) }),
    ("body", { $0.card.body }), ("pinned", { $0.card.isPinned }), ("conflictOf", { uuid($0.card.conflictOf) }),
    ("startedAt", { iso($0.card.startedAt) }), ("completedAt", { iso($0.card.completedAt) }),
    ("archivedAt", { iso($0.card.archivedAt) }), ("deletedAt", { iso($0.card.deletedAt) }),
    ("createdAt", { iso($0.card.createdAt) }), ("modifiedAt", { iso($0.card.modifiedAt) }),
  ])

  var json: JSONObject { Self.fields.json(self) }

  var line: String {
    "\(card.status.flatMap { Self.mark[$0] } ?? "")\(card.id.shortID)  \(project)  \(card.isPinned ? "★ " : "")\(title(card.body))"
      + (card.parentID.map { "  ↳ \($0.shortID)" } ?? "")
  }

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

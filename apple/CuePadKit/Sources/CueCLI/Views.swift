import CueStore
import CueText
import Foundation

typealias JSONObject = [String: any Sendable]

// MARK: 字段约定（改动须同步 Help.swift 的「JSON 结构」，测试会比对）

private func nullable<T: Sendable>(_ value: T?) -> any Sendable {
  guard let value else { return NSNull() }
  return value
}

private func uuid(_ id: UUID?) -> any Sendable { nullable(id?.uuidString.lowercased()) }

private func iso(_ date: Date?) -> any Sendable {
  nullable(date?.ISO8601Format(.init(includingFractionalSeconds: true)))
}

/// 文本输出里的短 id：命令的 `<卡片>`、`<任务>` 参数都接受唯一前缀。
private func short(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

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
      "pinned": project.isPinned, "goalCardId": uuid(project.goalCardID), "directory": nullable(directory),
      "cardCount": cardCount, "createdAt": iso(project.createdAt), "modifiedAt": iso(project.modifiedAt),
    ]
  }

  var line: String {
    "\(short(project.id))  \(project.isPinned ? "★ " : "")\(project.name)  \(cardCount) 张卡片"
      + (directory.map { "  \($0)" } ?? "")
  }
}

struct CardView {
  let card: Card
  let project: String?

  var json: JSONObject {
    [
      "id": uuid(card.id), "projectId": uuid(card.projectID), "project": nullable(project), "body": card.body,
      "pinned": card.isPinned, "conflictOf": uuid(card.conflictOf),
      "deletedAt": iso(card.deletedAt), "createdAt": iso(card.createdAt), "modifiedAt": iso(card.modifiedAt),
    ]
  }

  var line: String {
    "\(short(card.id))  \(project ?? "未归档")  \(card.isPinned ? "★ " : "")\(title(card.body))"
  }

  /// `card show` 的文本：元信息，空行，正文原样。
  var detail: String {
    var rows = ["id: \(card.id.uuidString.lowercased())", "项目: \(project ?? "未归档")"]
    if card.isPinned { rows.append("置顶: 是") }
    if let original = card.conflictOf { rows.append("冲突副本，原卡: \(original.uuidString.lowercased())") }
    if let deleted = card.deletedAt { rows.append("已删除: \(minutes(deleted))") }
    rows.append("修改: \(minutes(card.modifiedAt))")
    return rows.joined(separator: "\n") + "\n\n" + card.body
  }
}

struct TaskView {
  let task: CueTask
  let project: String?

  var json: JSONObject {
    [
      "id": uuid(task.id), "content": task.content, "projectId": uuid(task.projectID), "project": nullable(project),
      "done": task.completedAt != nil, "completedAt": iso(task.completedAt), "createdAt": iso(task.createdAt),
      "modifiedAt": iso(task.modifiedAt),
    ]
  }

  var line: String {
    "[\(task.completedAt == nil ? " " : "x")] \(short(task.id))  \(task.content)" + (project.map { "  (\($0))" } ?? "")
  }
}

// MARK: 从资料库取视图

extension Call {
  func projectNames() async throws -> [UUID: String] {
    let all = try await store.projects() + store.trashedProjects()
    return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
  }

  func cardViews(_ cards: [Card]) async throws -> [CardView] {
    let names = try await projectNames()
    return cards.map { CardView(card: $0, project: $0.projectID.flatMap { names[$0] }) }
  }

  func taskViews(_ tasks: [CueTask]) async throws -> [TaskView] {
    let names = try await projectNames()
    return tasks.map { TaskView(task: $0, project: $0.projectID.flatMap { names[$0] }) }
  }
}

func listReply(_ lines: [String], json: [JSONObject]) -> Reply {
  Reply(text: lines.isEmpty ? "（无）\n" : lines.joined(separator: "\n") + "\n", json: json)
}

func reply(_ view: CardView) -> Reply { Reply(text: view.line + "\n", json: view.json) }
func reply(_ view: TaskView) -> Reply { Reply(text: view.line + "\n", json: view.json) }

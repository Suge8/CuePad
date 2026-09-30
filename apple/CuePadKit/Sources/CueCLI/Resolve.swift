import CueStore
import Foundation

/// 项目：id 或名称（不分大小写）；对象：完整 id 或唯一前缀。
extension Call {
  func project(_ ref: String) async throws -> Project {
    let live = try await store.projects()
    if let id = UUID(uuidString: ref), let hit = live.first(where: { $0.id == id }) { return hit }
    let named = live.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    if named.count > 1 {
      throw CLIError(
        kind: .ambiguous,
        message: "项目名称「\(ref)」有 \(named.count) 个，请改用 id：\n"
          + named.map { "  \($0.id.uuidString.lowercased())  \($0.name)" }.joined(separator: "\n"))
    }
    if let hit = named.first { return hit }
    let byPrefix = live.filter { matches(ref, $0.id) }
    if byPrefix.count == 1 { return byPrefix[0] }
    let available = live.isEmpty ? "还没有项目" : "现有项目：" + live.map(\.name).joined(separator: "、")
    throw CLIError.notFound("找不到项目「\(ref)」。\(available)（cuepad project list）")
  }

  /// 含回收站里的卡片，也含随项目进回收站的卡片。
  func card(_ ref: String) async throws -> Card {
    if let id = UUID(uuidString: ref) {
      guard let card = try await store.card(id) else { throw CLIError.notFound("找不到卡片 \(ref)") }
      return card
    }
    let everything = try await store.search(SearchQuery(), limit: .max).cards
      + store.search(SearchQuery(inTrash: true), limit: .max).cards
    return try unique(ref, in: everything, kind: "卡片") { $0.body }
  }

  func task(_ ref: String) async throws -> CueTask {
    if let id = UUID(uuidString: ref) {
      guard let task = try await findTask(id) else { throw CLIError.notFound("找不到任务 \(ref)") }
      return task
    }
    let all = try await store.tasks() + store.completedTasks()
    return try unique(ref, in: all, kind: "任务") { $0.content }
  }

  func findTask(_ id: UUID) async throws -> CueTask? {
    let all = try await store.tasks() + store.completedTasks()
    return all.first { $0.id == id }
  }

  private func unique<T: Identifiable>(
    _ ref: String, in items: [T], kind: String, describe: (T) -> String
  ) throws -> T where T.ID == UUID {
    let hits = items.filter { matches(ref, $0.id) }
    if hits.count == 1 { return hits[0] }
    guard hits.count > 1 else { throw CLIError.notFound("找不到\(kind) \(ref)（id 或至少 4 位的唯一前缀）") }
    let lines = hits.map { "  \($0.id.uuidString.lowercased())  \(describe($0).prefix(30))" }
    throw CLIError(kind: .ambiguous, message: "前缀「\(ref)」匹配到 \(hits.count) 个\(kind)，请写长一点：\n" + lines.joined(separator: "\n"))
  }

  private func matches(_ ref: String, _ id: UUID) -> Bool {
    ref.count >= 4 && id.uuidString.lowercased().hasPrefix(ref.lowercased())
  }
}

/// `--project 项目` 与 `--inbox` 二选一的范围。
enum Scope {
  case any, inbox, project(Project)

  /// 新建与移动的落点：未指定等同未归档。
  var target: UUID? {
    if case .project(let project) = self { return project.id }
    return nil
  }

  func contains(_ projectID: UUID?) -> Bool {
    switch self {
    case .any: true
    case .inbox: projectID == nil
    case .project(let project): projectID == project.id
    }
  }
}

extension Call {
  func scope() async throws -> Scope {
    let ref = args.value("project")
    if ref != nil, args.has("inbox") { throw CLIError.usage("--project 与 --inbox 只能选一个") }
    if let ref { return .project(try await project(ref)) }
    return args.has("inbox") ? .inbox : .any
  }

  /// 正文：`--body` 优先，否则 stdin。stdin 为空视为误操作（没接管道的 agent 会得到空串）。
  func bodyInput() throws -> String {
    if let body = args.value("body") { return body }
    guard let piped = stdin() else {
      throw CLIError.usage("需要正文：--body 正文，或从 stdin 传入（例如 printf '...' | cuepad card add）")
    }
    guard !piped.isEmpty else { throw CLIError.invalid("stdin 为空，没有可写入的正文；要空正文请显式传 --body ''") }
    return piped
  }
}

extension Optional {
  func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let self else { return nil }
    return try await transform(self)
  }
}

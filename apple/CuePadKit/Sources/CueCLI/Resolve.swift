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
    throw CLIError.notFound("找不到项目「\(ref)」。现有项目：\(live.map(\.name).joined(separator: "、"))（cuepad project list）")
  }

  /// 含回收站里的卡片，也含随项目进回收站的卡片。
  func card(_ ref: String) async throws -> Card {
    if let id = UUID(uuidString: ref) {
      guard let card = try await store.card(id) else { throw CLIError.notFound("找不到灵感或任务 \(ref)") }
      return card
    }
    return try await unique(ref, kind: "灵感或任务", describe: { $0.body }) { try await store.cards(idPrefix: ref) }
  }

  /// 任务（要做的卡片）：id 或唯一前缀，只在可见任务里找。
  func task(_ ref: String) async throws -> Card {
    let all = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
    if let id = UUID(uuidString: ref) {
      guard let task = all.first(where: { $0.id == id }) else { throw CLIError.notFound("找不到任务 \(ref)") }
      return task
    }
    return try await unique(ref, kind: "任务", describe: { $0.body }) { all.filter { matches(ref, $0.id) } }
  }

  /// 前缀至少 4 位才查；`candidates` 给出以它开头的全部对象。
  private func unique<T: Identifiable>(
    _ ref: String, kind: String, describe: (T) -> String, candidates: () async throws -> [T]
  ) async throws -> T where T.ID == UUID {
    let hits = ref.count >= 4 ? try await candidates() : []
    if hits.count == 1 { return hits[0] }
    guard hits.count > 1 else { throw CLIError.notFound("找不到\(kind) \(ref)（id 或至少 4 位的唯一前缀）") }
    let lines = hits.map { "  \($0.id.uuidString.lowercased())  \(describe($0).prefix(30))" }
    throw CLIError(kind: .ambiguous, message: "前缀「\(ref)」匹配到 \(hits.count) 个\(kind)，请写长一点：\n" + lines.joined(separator: "\n"))
  }

  private func matches(_ ref: String, _ id: UUID) -> Bool {
    ref.count >= 4 && id.uuidString.lowercased().hasPrefix(ref.lowercased())
  }
}

/// `--project 项目` 给的范围，或不限。
enum Scope {
  case any, project(Project)

  /// 新建的落点：没指定项目（也不在绑定了目录的项目里）的进默认项目。
  var target: UUID {
    if case .project(let project) = self { return project.id }
    return Project.defaultID
  }

  func contains(_ projectID: UUID) -> Bool {
    switch self {
    case .any: true
    case .project(let project): projectID == project.id
    }
  }
}

extension Call {
  /// `--project 项目` 与 `--all-projects` 二选一；都没给时，`implicit` 为真则用绑定了当前目录的项目，没有就不限。
  func scope(implicit: Bool = true) async throws -> Scope {
    let ref = args.value("project")
    if ref != nil, args.has("all-projects") { throw CLIError.usage("--project 与 --all-projects 只能选一个") }
    if let ref { return .project(try await project(ref)) }
    if args.has("all-projects") || !implicit { return .any }
    return try await store.project(containing: URL(filePath: directory)).map(Scope.project) ?? .any
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

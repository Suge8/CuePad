import CueStore
import Foundation

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

  func card(_ ref: String) async throws -> Card {
    if let id = UUID(uuidString: ref) {
      guard let card = try await store.card(id) else { throw CLIError.notFound("找不到灵感或任务 \(ref)（cuepad search 查找）") }
      return card
    }
    return try await unique(ref, kind: "灵感或任务", lister: "cuepad search", describe: { $0.body }) { try await store.cards(idPrefix: ref) }
  }

  func task(_ ref: String) async throws -> Card {
    let all = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
    if let id = UUID(uuidString: ref) {
      guard let task = all.first(where: { $0.id == id }) else { throw CLIError.notFound("找不到任务 \(ref)（cuepad task list --all 查看）") }
      return task
    }
    return try await unique(ref, kind: "任务", lister: "cuepad task list --all", describe: { $0.body }) { all.filter { matches(ref, $0.id) } }
  }

  private func unique<T: Identifiable>(
    _ ref: String, kind: String, lister: String, describe: (T) -> String, candidates: () async throws -> [T]
  ) async throws -> T where T.ID == UUID {
    let hits = ref.count >= 4 ? try await candidates() : []
    if hits.count == 1 { return hits[0] }
    guard hits.count > 1 else { throw CLIError.notFound("找不到\(kind) \(ref)：写 id 或至少 4 位的唯一前缀（\(lister) 查看）") }
    let lines = hits.map { "  \($0.id.uuidString.lowercased())  \(describe($0).prefix(30))" }
    throw CLIError(kind: .ambiguous, message: "前缀「\(ref)」匹配到 \(hits.count) 个\(kind)，请写长一点：\n" + lines.joined(separator: "\n"))
  }

  private func matches(_ ref: String, _ id: UUID) -> Bool {
    ref.count >= 4 && id.uuidString.lowercased().hasPrefix(ref.lowercased())
  }
}

enum Scope {
  case any, project(Project)

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
  func scope(implicit: Bool = true) async throws -> Scope {
    let ref = args.value("project")
    if ref != nil, args.has("all-projects") { throw CLIError.usage("--project 与 --all-projects 只能选一个") }
    if let ref { return .project(try await project(ref)) }
    if args.has("all-projects") || !implicit { return .any }
    return try await store.project(containing: URL(filePath: directory)).map(Scope.project) ?? .any
  }

  func bodyInput() throws -> String {
    if let body = args.value("body") { return body }
    guard let piped = stdin() else {
      throw CLIError.usage("需要正文：--body 正文，或从 stdin 传入（例如 printf '...' | cuepad card add）")
    }
    guard !piped.isEmpty else { throw CLIError.invalid("stdin 为空，没有可写入的正文；要空正文请显式传 --body ''") }
    return piped
  }
}

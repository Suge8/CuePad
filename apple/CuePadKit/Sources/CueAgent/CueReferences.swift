import CueStore
import Foundation

struct CueReferences {
  let store: CueStore
  typealias Failure = CueTools.Failure

  func project(_ ref: String) async throws -> Project {
    let all = try await store.projects()
    if let hit = all.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) && ref.count >= 4 }) {
      return hit
    }
    throw Failure("没有项目「\(ref)」。现有：" + (all.isEmpty ? "无" : all.map(\.name).joined(separator: "、")))
  }

  func addProject(_ args: Args) async throws -> UUID {
    try await addProject(args, session: args.string("session").asyncMap(session))
  }

  func addProject(_ args: Args, session: SessionState?) async throws -> UUID {
    if let ref = args.string("project") { return try await project(ref).id }
    if let home = session?.projectID, let project = try await store.projects().first(where: { $0.id == home }) { return project.id }
    return Project.defaultID
  }

  func task(_ ref: String) async throws -> Card {
    if let card = try await findTask(ref) { return card }
    let key = ref.trimmingCharacters(in: .whitespaces)
    if let session = try? await matchedSession(key) {
      throw Failure("「\(key)」是会话「\(session.title)」，不是任务：这里写任务的 id 或标题（peek 里有）")
    }
    throw Failure("找不到任务「\(key)」：用 task peek 看看板上的 id")
  }

  func openTopTask(titled heading: String, in project: UUID) async throws -> Card? {
    try await store.tasks(.todo, .inProgress).flatMap(\.tasks)
      .filter { $0.parentID == nil && $0.projectID == project && $0.heading.caseInsensitiveCompare(heading) == .orderedSame }
      .sorted { $0.createdAt > $1.createdAt }.first
  }

  private func findTask(_ ref: String) async throws -> Card? {
    let key = ref.trimmingCharacters(in: .whitespaces)
    if let uuid = UUID(uuidString: key), let card = try await store.card(uuid), card.isTask, card.deletedAt == nil { return card }
    if key.count >= 4, key.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
      let hits = try await store.cards(idPrefix: key).filter { $0.isTask && $0.deletedAt == nil }
      if hits.count == 1 { return hits[0] }
      if hits.count > 1 { throw Failure("前缀 \(key) 对上了 \(hits.count) 个任务：多写几位") }
    }
    let named = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).filter { $0.heading.caseInsensitiveCompare(key) == .orderedSame }
    if named.count > 1 { throw Failure("有 \(named.count) 个任务叫「\(key)」：用 id（peek 里有）") }
    return named.first
  }

  func session(_ ref: String) async throws -> SessionState {
    switch try await sessionRef(ref) {
    case .session(let session): return session
    case .task(let card):
      let id = try await store.leafSession(try await store.workingLeaf(of: card.id).id)
      guard let session = try await store.sessions(matching: id).first else { throw Failure("找不到「\(card.heading)」的会话：用 task peek 看看") }
      return session
    }
  }

  func place(_ args: Args) async throws -> SessionRef? {
    if let ref = args.string("task") {
      if let card = try await findTask(ref) { return .task(card) }
      if let session = try await matchedSession(ref) { return .session(session) }
      throw Failure("找不到任务或会话「\(ref.trimmingCharacters(in: .whitespaces))」：用 task peek 看 id")
    }
    return try await args.string("session").asyncMap(sessionRef)
  }

  func sessionRef(_ ref: String) async throws -> SessionRef {
    if let session = try await matchedSession(ref) { return .session(session) }
    guard let card = try await findTask(ref) else { throw Failure("找不到会话或任务「\(ref)」：用 task peek 看 id") }
    return .task(card)
  }

  private func matchedSession(_ ref: String) async throws -> SessionState? {
    let hits = try await store.sessions(matching: ref)
    let live = hits.filter { $0.state != .known(.ended) }
    if hits.count == 1 { return hits[0] }
    if live.count == 1 { return live[0] }
    if hits.count > 1 { throw Failure("「\(ref)」对上了 \(hits.count) 个会话：用会话 id（peek 里有）") }
    return nil
  }

  enum SessionRef {
    case session(SessionState)
    case task(Card)
  }

  func workingLeaf(_ ref: String) async throws -> Card {
    try await store.workingLeaf(of: try await task(ref).id)
  }

}

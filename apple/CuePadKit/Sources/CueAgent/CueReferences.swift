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

  func addProject(_ args: Args, session: PiSessionState?) async throws -> UUID {
    if let ref = args.string("project") { return try await project(ref).id }
    if let home = session?.projectID, let project = try await store.projects().first(where: { $0.id == home }) { return project.id }
    return Project.defaultID
  }

  /// 任务：id、至少 4 位的 id 前缀，或标题（不分大小写，只在没删除的任务里找）。写的是会话就说清楚这里要任务。
  func task(_ ref: String) async throws -> Card {
    if let card = try await findTask(ref) { return card }
    let key = ref.trimmingCharacters(in: .whitespaces)
    if let session = try? await matchedSession(key) {
      throw Failure("「\(key)」是会话「\(session.title)」，不是任务：这里写任务的 id 或标题（peek 里有）")
    }
    throw Failure("找不到任务「\(key)」：用 task peek 看看板上的 id")
  }

  /// 没做完、叫这个名字（不分大小写）的顶层任务，后建的在前：add 认同一件事、经过清单认 add 建的那件都按它，做完的同名旧任务不算。
  func openTopTask(titled heading: String, in project: UUID) async throws -> Card? {
    try await store.tasks(.todo, .inProgress).flatMap(\.tasks)
      .filter { $0.parentID == nil && $0.projectID == project && $0.heading.caseInsensitiveCompare(heading) == .orderedSame }
      .sorted { $0.createdAt > $1.createdAt }.first
  }

  /// 同 `task`，对不上为 nil；对上好几个照样报错（要多写几位，不是找不到）。
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

  /// 会话：会话 id 至少 4 位的前缀或会话名（`CueStore.sessions(matching:)`）；同名的几个里只有一个没结束就是它。写的是任务时是它在做的叶子绑着的会话。
  func session(_ ref: String) async throws -> PiSessionState {
    switch try await sessionRef(ref) {
    case .session(let session): return session
    case .task(let card):
      let id = try await store.leafSession(try await store.workingLeaf(of: card.id).id)
      guard let session = try await store.sessions(matching: id).first else { throw Failure("找不到「\(card.heading)」的会话：用 task peek 看看") }
      return session
    }
  }

  /// say、peek、stop、leave、take 对的那一处（经过里认它的也是这条）：task、session 两个参数都认任务与会话的编号，写在 task 先认任务、
  /// 写在 session 先认会话。信封按任务列会话、只写任务的编号，不归任务的会话只有会话的编号：模型两种编号常填错参数，在这里收成一处都认。都没给为 nil。
  func place(_ args: Args) async throws -> SessionRef? {
    if let ref = args.string("task") {
      if let card = try await findTask(ref) { return .task(card) }
      if let session = try await matchedSession(ref) { return .session(session) }
      throw Failure("找不到任务或会话「\(ref.trimmingCharacters(in: .whitespaces))」：用 task peek 看 id")
    }
    return try await args.string("session").asyncMap(sessionRef)
  }

  /// session 写的引用：对不上会话时也认任务的 id 前缀或标题。
  func sessionRef(_ ref: String) async throws -> SessionRef {
    if let session = try await matchedSession(ref) { return .session(session) }
    guard let card = try await findTask(ref) else { throw Failure("找不到会话或任务「\(ref)」：用 task peek 看 id") }
    return .task(card)
  }

  /// 对上的会话（`CueStore.sessions(matching:)`）：只有一个，或同名的几个里只有一个没结束；对不上为 nil，对上几个报错。
  private func matchedSession(_ ref: String) async throws -> PiSessionState? {
    let hits = try await store.sessions(matching: ref)
    let live = hits.filter { $0.state != .known(.ended) }
    if hits.count == 1 { return hits[0] }
    if live.count == 1 { return live[0] }
    if hits.count > 1 { throw Failure("「\(ref)」对上了 \(hits.count) 个会话：用会话 id（peek 里有）") }
    return nil
  }

  enum SessionRef {
    case session(PiSessionState)
    case task(Card)
  }

  /// 任务此刻在做的叶子（给顶层任务时是它在做的那个子任务）。
  func workingLeaf(_ ref: String) async throws -> Card {
    try await store.workingLeaf(of: try await task(ref).id)
  }

}

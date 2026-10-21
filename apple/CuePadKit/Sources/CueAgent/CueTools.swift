import CueStore
import CueText
import Foundation

/// Cue 的三个工具（task、tell、memory）：定义与实现。都经 `CueStore` 的业务操作，写出的投送请求与消息标明来自 Cue。
/// 返回一两句人话加 id，只有正文（三家大脑给模型看的都是这一份）；出错给出路（`isError`）。
public struct CueTools: Sendable {
  let store: CueStore
  /// 说话类请求写下后等结果多久（`Speech.cueWait`；测试给短的）。
  let wait: TimeInterval

  public init(store: CueStore, wait: TimeInterval = Speech.cueWait) {
    self.store = store
    self.wait = wait
  }

  /// 一次调用的结果（MCP 的 `CallToolResult`）。
  public struct Result: Sendable {
    public var text: String
    public var isError: Bool

    static func ok(_ text: String) -> Result { Result(text: text, isError: false) }
  }

  /// 给 Cue 看的出错：说清楚、给出路。
  struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  /// 调用一个工具；工具名不认识返回 nil（协议层报参数错）。业务上的失败是 `isError` 的结果。
  public func call(_ name: String, _ arguments: [String: Any]) async -> Result? {
    let args = Args(raw: arguments)
    do {
      switch name {
      case "task": return try await task(args)
      case "tell": return try await tell(args)
      case "memory": return try await memory(args)
      default: return nil
      }
    } catch let failure as Failure {
      return Result(text: failure.message, isError: true)
    } catch {
      // Kit 里只有 Cue 会碰到的错误，文案本来就是写给 Cue 的（见 `CueStoreError`）
      return Result(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", isError: true)
    }
  }

  func host() async throws -> String {
    guard let host = try await store.cueProfile()?.activeHost else { throw CueStoreError.cueNotEnabled }
    return host
  }

  func project(_ ref: String) async throws -> Project {
    let all = try await store.projects()
    if let hit = all.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) && ref.count >= 4 }) {
      return hit
    }
    throw Failure("没有项目「\(ref)」。现有：" + (all.isEmpty ? "无" : all.map(\.name).joined(separator: "、")))
  }

  /// 任务：id、至少 4 位的 id 前缀，或标题（不分大小写，只在没删除的任务里找）。
  func task(_ ref: String) async throws -> Card {
    guard let card = try await findTask(ref) else { throw Failure("找不到任务「\(ref.trimmingCharacters(in: .whitespaces))」：用 task peek 看看板上的 id") }
    return card
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

  /// session 写的引用：对不上会话时也认任务的 id 前缀或标题。
  /// 信封与看板按任务列会话、只写任务的编号，"对会话说"时模型自然把它填进 session：两套编号在这里收成一个参数都认。
  func sessionRef(_ ref: String) async throws -> SessionRef {
    let hits = try await store.sessions(matching: ref)
    let live = hits.filter { $0.state != .known(.ended) }
    if hits.count == 1 { return .session(hits[0]) }
    if live.count == 1 { return .session(live[0]) }
    if hits.count > 1 { throw Failure("「\(ref)」对上了 \(hits.count) 个会话：用会话 id（peek 里有）") }
    guard let card = try await findTask(ref) else { throw Failure("找不到会话或任务「\(ref)」：用 task peek 看 id") }
    return .task(card)
  }

  enum SessionRef {
    case session(PiSessionState)
    case task(Card)
  }

  /// 任务此刻在做的叶子（给顶层任务时是它在做的那个步骤）。
  func workingLeaf(_ ref: String) async throws -> Card {
    try await store.workingLeaf(of: try await task(ref).id)
  }

  func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

struct Args {
  let raw: [String: Any]

  func string(_ key: String) -> String? { raw[key] as? String }

  func required(_ key: String) throws -> String {
    guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CueTools.Failure("缺少 \(key)")
    }
    return value
  }

  func strings(_ key: String) -> [String]? { raw[key] as? [String] }

  func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber)?.boolValue }

  func int(_ key: String) -> Int? {
    if let number = raw[key] as? NSNumber { return number.intValue }
    return (raw[key] as? String).flatMap { Int($0) }
  }
}

extension Optional {
  func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let self else { return nil }
    return try await transform(self)
  }
}

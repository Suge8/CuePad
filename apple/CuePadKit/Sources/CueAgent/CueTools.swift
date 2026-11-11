import CueStore
import CueText
import Foundation

/// Cue 的工具与后台整理记忆的工具（merge）：定义与实现。都经 `CueStore` 的业务操作，写出的投送请求与消息标明来自 Cue。
/// 返回一两句人话加 id，只有正文（各家大脑给模型看的都是这一份）；出错给出路（`isError`）。
public struct CueTools: Sendable {
  let store: CueStore
  /// 说话类请求写下后等结果多久（`Speech.cueWait`；测试给短的）。
  let wait: TimeInterval
  let toolset: Toolset

  public enum Toolset: Sendable {
    case cue, dream
  }

  /// 清掉一项的写法（task edit 的 body、setup project 的 intro 与 folder）：空值是没写（`Args.given`）。
  static let cleared = "none"

  public init(store: CueStore, wait: TimeInterval = Speech.cueWait, toolset: Toolset = .cue) {
    self.store = store
    self.wait = wait
    self.toolset = toolset
  }

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
    let args = Args(arguments)
    do {
      switch (toolset, name) {
      case (.cue, "idea"): return try await idea(args)
      case (.cue, "task"): return try await task(args)
      case (.cue, "tell"): return try await tell(args)
      case (.cue, "memory"): return try await memory(args)
      case (.cue, "setup"): return try await setup(args)
      case (.dream, "merge"): return try await merge(args)
      default: return nil
      }
    } catch {
      return Result(text: Self.message(error), isError: true)
    }
  }

  /// 出错给 Cue 看的那句：Kit 里只有 Cue 会碰到的错误，文案本来就是写给 Cue 的（见 `CueStoreError`）。
  static func message(_ error: any Error) -> String {
    (error as? Failure)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }

  func host() async throws -> String {
    guard let host = try await store.cueProfile()?.activeHost else { throw CueStoreError.cueNotEnabled }
    return host
  }

  var references: CueReferences { CueReferences(store: store) }

  func iso(_ date: Date) -> String { date.formatted(.iso8601) }
}

struct Args {
  let raw: [String: Any]

  init(_ arguments: [String: Any]) { raw = Self.given(arguments) }

  /// 模型写了的参数：去掉 null、空白字符串与空数组。有的模型把没用到的可选参数一律填成空值，当成写了就会去找叫空串的任务、
  /// 把空的 ask 当成提问；没有哪个参数靠空值表达意思（回到默认写 default，清掉写 none）。
  static func given(_ arguments: [String: Any]) -> [String: Any] {
    arguments.filter { _, value in
      switch value {
      case is NSNull: false
      case let text as String: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      case let list as [Any]: !list.isEmpty
      default: true
      }
    }
  }

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

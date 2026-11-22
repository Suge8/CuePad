import CueStore
import CueText
import Foundation

public struct CueTools: Sendable {
  let store: CueStore
  let wait: TimeInterval
  let toolset: Toolset

  public enum Toolset: Sendable {
    case cue, dream
  }

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

  struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  struct Tool {
    let name: String
    let gist: String
    let definition: () -> [String: Any]
    let run: (CueTools, Args) async throws -> Result
  }

  enum DreamTool: String {
    case merge, said, keep
  }

  static func catalog(_ toolset: Toolset) -> [Tool] {
    switch toolset {
    case .cue:
      [
        Tool(name: "idea", gist: "保存灵感", definition: { ideaDefinition }, run: { try await $0.idea($1) }),
        Tool(name: "task", gist: "任务与会话", definition: { taskDefinition }, run: { try await $0.task($1) }),
        Tool(name: "tell", gist: "对他说话", definition: { tellDefinition }, run: { try await $0.tell($1) }),
        Tool(name: "memory", gist: "记忆与定时", definition: { memoryDefinition }, run: { try await $0.memory($1) }),
        Tool(name: "setup", gist: "你自己与这台 Mac：设置、额度、Agent、技能与规则、项目", definition: { setupDefinition }, run: { try await $0.setup($1) }),
      ]
    case .dream:
      [
        Tool(name: DreamTool.merge.rawValue, gist: "", definition: { mergeDefinition }, run: { try await $0.merge($1) }),
        Tool(name: DreamTool.said.rawValue, gist: "", definition: { saidDefinition }, run: { try await $0.said($1) }),
        Tool(name: DreamTool.keep.rawValue, gist: "", definition: { keepDefinition }, run: { try await $0.keep($1) }),
      ]
    }
  }

  public func call(_ name: String, _ arguments: [String: Any]) async -> Result? {
    guard let tool = Self.catalog(toolset).first(where: { $0.name == name }) else { return nil }
    do {
      return try await tool.run(self, Args(arguments))
    } catch {
      return Result(text: Self.message(error), isError: true)
    }
  }

  static func message(_ error: any Error) -> String {
    if let failure = error as? Failure { return failure.message }
    let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    return (error as? CueStoreError)?.cueAdvice.map { "\(text)：\($0)" } ?? text
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

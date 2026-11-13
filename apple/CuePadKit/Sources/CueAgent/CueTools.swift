import CueStore
import CueText
import Foundation

/// Cue 的工具与后台整理记忆的工具（merge、said、ask）：定义与实现。都经 `CueStore` 的业务操作，写出的投送请求与消息标明来自 Cue。
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

  /// 一个工具只在 `catalog` 登记一次：给模型的定义（`definitions`）、调用的分派（`call`）与系统提示里的名单（`CuePrompt`）都从它出。
  struct Tool {
    let name: String
    /// 系统提示的工具名单里那几个字；做梦的工具不进系统提示
    let gist: String
    /// 说明、参数与提示（名字由 `name` 补上）
    let definition: () -> [String: Any]
    let run: (CueTools, Args) async throws -> Result
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
        Tool(name: "merge", gist: "", definition: { mergeDefinition }, run: { try await $0.merge($1) }),
        Tool(name: "said", gist: "", definition: { saidDefinition }, run: { try await $0.said($1) }),
        Tool(name: "ask", gist: "", definition: { askDefinition }, run: { try await $0.ask($1) }),
      ]
    }
  }

  /// 调用一个工具；工具名不认识返回 nil（协议层报参数错）。业务上的失败是 `isError` 的结果。
  public func call(_ name: String, _ arguments: [String: Any]) async -> Result? {
    guard let tool = Self.catalog(toolset).first(where: { $0.name == name }) else { return nil }
    do {
      return try await tool.run(self, Args(arguments))
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

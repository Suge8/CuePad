import Foundation

// 会话记录上随 Pi 桥上报的几块值：弹窗、模型配置、上下文余量、斜杠命令、子代理。桥（CuePi）直接解码成这些类型，
// 记录器原样写入同步记录；这里的 Codable 形状就是同步字段里 JSON 的格式（线上格式不能改）。

public enum PiQuestionKind: String, Sendable, CaseIterable, Codable {
  /// 是或否
  case confirm
  /// 从选项里选一个
  case select
  /// 填一段文字
  case text
}

/// 等你回答的弹窗。存在同步记录的 `question` 字段里（加密，JSON）。
public struct PiQuestion: Sendable, Equatable, StoredJSON {
  /// 这次弹窗的标识，作答时带上；nil 表示只能在 Pi 里答（多行编辑、自定义界面）。
  public var promptID: String?
  /// 不认识的种类（多行编辑、自定义界面、更新版本的新种类）不能从这里作答。
  public var kind: Open<PiQuestionKind>
  /// 标题与说明，换行分隔，至多 500 字符。
  public var text: String
  /// 选择框的选项原文，作答时按原文回传。
  public var options: [String]

  public init(promptID: String?, kind: Open<PiQuestionKind>, text: String, options: [String] = []) {
    self.promptID = promptID
    self.kind = kind
    self.text = text
    self.options = options
  }

  public init(promptID: String?, kind: PiQuestionKind, text: String, options: [String] = []) {
    self.init(promptID: promptID, kind: .known(kind), text: text, options: options)
  }

  /// 能从 CuePad 作答：有标识，种类认识。
  public var isAnswerable: Bool { promptID != nil && kind.known != nil }

  /// 同步记录里的 `question` 字段（通知扩展也读它）；读不成 JSON 按没有提问处理，不让整条记录解码失败。
  public init?(stored: String) {
    guard let value = JSONColumn.decode(Self.self, from: stored) else { return nil }
    self = value
  }
}

/// Pi 的思考强度（Pi 的 `ThinkingLevel`，含关闭）。
public enum PiThinkingLevel: String, Sendable, CaseIterable, Codable {
  case off, minimal, low, medium, high, xhigh, max
}

/// 一个模型的标识：提供方加模型 id（同一个 id 可以出自不同提供方）。
public struct PiModelKey: Sendable, Hashable, Codable {
  public var provider: String
  public var id: String

  public init(provider: String, id: String) {
    self.provider = provider
    self.id = id
  }
}

/// 会话可选的一个模型：标识、显示名，以及它支持的思考强度（不支持思考的只有 `off`；不认识的新强度读出时丢掉）。
/// JSON 里 provider、id 与 name 平铺，强度叫 `thinking`（Pi 桥上报的格式同此）。
public struct PiModelOption: Sendable, Equatable, Identifiable, Codable {
  public var key: PiModelKey
  public var name: String
  public var thinkingLevels: [PiThinkingLevel]
  public var id: PiModelKey { key }

  public init(key: PiModelKey, name: String, thinkingLevels: [PiThinkingLevel]) {
    self.key = key
    self.name = name
    self.thinkingLevels = thinkingLevels
  }

  private enum CodingKeys: String, CodingKey {
    case provider, id, name
    case thinking
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      key: PiModelKey(provider: try c.decode(String.self, forKey: .provider), id: try c.decode(String.self, forKey: .id)),
      name: try c.decode(String.self, forKey: .name),
      thinkingLevels: try c.decode([String].self, forKey: .thinking).compactMap(PiThinkingLevel.init(rawValue:)))
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key.provider, forKey: .provider)
    try c.encode(key.id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(thinkingLevels.map(\.rawValue), forKey: .thinking)
  }
}

/// 一个会话此刻的模型配置：当前模型与思考强度、可以换成的模型。Pi 桥上报，状态记录器整体写入。
public struct PiModelState: Sendable, Equatable {
  public var model: PiModelOption?
  public var thinking: Open<PiThinkingLevel>?
  public var models: [PiModelOption]

  public init(model: PiModelOption? = nil, thinking: Open<PiThinkingLevel>? = nil, models: [PiModelOption] = []) {
    self.model = model
    self.thinking = thinking
    self.models = models
  }
}

/// 会话的上下文余量：已用 token 与当前模型的上下文窗口（Pi 桥上报；Pi 在压缩后到下一次回答前不知道已用多少，`tokens` 为 nil）。
public struct PiContextUsage: Sendable, Equatable, Codable {
  public var tokens: Int?
  public var window: Int

  public init(tokens: Int?, window: Int) {
    self.tokens = tokens
    self.window = window
  }

  /// 已用比例（0 到 1，超出窗口夹到 1）；未知为 nil。
  public var fraction: Double? {
    guard let tokens, window > 0 else { return nil }
    return min(1, Double(tokens) / Double(window))
  }
}

/// 斜杠命令的来源：Pi 内置里能在非 TUI 下执行的、扩展命令、提示词模板、skill。
public enum PiCommandSource: String, Sendable, CaseIterable, Codable {
  case builtin, `extension`, prompt, skill
}

/// 会话此刻能用的一条斜杠命令（Pi 桥上报，随会话记录同步）。`name` 不带斜杠（skill 是 `skill:名字`）；`hint` 是参数提示，nil 表示不带参数。
public struct PiSlashCommand: Sendable, Equatable, Identifiable, Codable {
  public var name: String
  public var summary: String?
  public var source: Open<PiCommandSource>
  public var hint: String?
  public var id: String { name }

  public init(name: String, summary: String?, source: Open<PiCommandSource>, hint: String? = nil) {
    self.name = name
    self.summary = summary
    self.source = source
    self.hint = hint
  }
}

/// 子代理此刻的状态，即 FireCode 子代理名册的分组：在跑、在审查、已交回结果、失败、被中断、空闲。
public enum PiSubagentPhase: String, Sendable, CaseIterable, Codable {
  case running, review, done, failed, interrupted, idle
}

/// 会话里的一个子代理（来自 FireCode 的子代理名册）：名字、派发角色、状态、在做什么，以及本次运行的开始与落定时刻
/// （界面据此算"已工作多久"；落定后时长停在落定时刻）。JSON 里状态叫 `state`，时刻是 1970 年起的秒。
public struct PiSubagentState: Sendable, Equatable, Codable {
  public var name: String
  public var role: String
  public var phase: Open<PiSubagentPhase>
  /// 在做什么的一句话；空闲时为空
  public var action: String
  public var startedAt: Date?
  public var settledAt: Date?

  public init(
    name: String, role: String, phase: Open<PiSubagentPhase>, action: String = "", startedAt: Date? = nil, settledAt: Date? = nil
  ) {
    self.name = name
    self.role = role
    self.phase = phase
    self.action = action
    self.startedAt = startedAt
    self.settledAt = settledAt
  }

  /// 去掉"在做什么"的样子：谁在、什么角色、什么状态。动作文字随每次工具调用变，不算名册变了（记录器据此不为它绕开写入节流）。
  var shape: PiSubagentState {
    var shape = self
    shape.action = ""
    return shape
  }

  private enum CodingKeys: String, CodingKey {
    case name, role, action, startedAt, settledAt
    case phase = "state"
  }
}

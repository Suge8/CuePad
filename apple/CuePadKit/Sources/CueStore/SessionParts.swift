import Foundation

public enum QuestionKind: String, Sendable, CaseIterable, Codable {
  case confirm
  case select
  case text
}

public struct Question: Sendable, Equatable, StoredJSON {
  public var promptID: String?
  public var kind: Open<QuestionKind>
  public var text: String
  public var options: [String]
  /// 选择题也能自己填（Agent 本身就给"其他"的：Claude Code 的提问、Codex 带 `isOther` 的、OpenCode 带 `custom` 的）
  public var allowsOther: Bool

  public init(promptID: String?, kind: Open<QuestionKind>, text: String, options: [String] = [], allowsOther: Bool = false) {
    self.promptID = promptID
    self.kind = kind
    self.text = text
    var seen: Set<String> = []
    self.options = options.filter { seen.insert($0).inserted }
    self.allowsOther = allowsOther
  }

  public init(promptID: String?, kind: QuestionKind, text: String, options: [String] = [], allowsOther: Bool = false) {
    self.init(promptID: promptID, kind: .known(kind), text: text, options: options, allowsOther: allowsOther)
  }

  public var isAnswerable: Bool { promptID != nil && kind.known != nil }

  public var acceptsText: Bool { kind == .known(.text) || (kind == .known(.select) && allowsOther) }

  public init?(stored: String) {
    guard let value = JSONColumn.decode(Self.self, from: stored) else { return nil }
    self = value
  }
}

public enum ThinkingLevel: String, Sendable, CaseIterable, Codable {
  case off, minimal, low, medium, high, xhigh, max

  public func clamped(to supported: [ThinkingLevel]) -> ThinkingLevel {
    guard !supported.isEmpty, !supported.contains(self) else { return self }
    let rank = { (level: ThinkingLevel) in Self.allCases.firstIndex(of: level)! }
    return supported.min { (abs(rank($0) - rank(self)), rank($0)) < (abs(rank($1) - rank(self)), rank($1)) }!
  }
}

public struct ModelKey: Sendable, Hashable, Codable {
  public var provider: String
  public var id: String

  public init(provider: String, id: String) {
    self.provider = provider
    self.id = id
  }
}

public struct PiProof: Sendable, Equatable, Decodable {
  public var provider: String
  public var id: String
  public var account: PiAccount
  public var at: Date

  public init(provider: String, id: String, account: PiAccount, at: Date) {
    self.provider = provider
    self.id = id
    self.account = account
    self.at = at
  }

  private enum CodingKeys: String, CodingKey { case provider, id, account, at }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try c.decode(String.self, forKey: .provider), id: try c.decode(String.self, forKey: .id),
      account: try c.decode(PiAccount.self, forKey: .account), at: Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .at)))
  }
}

/// 会话可选的一个模型：标识、显示名，它支持的思考强度（不支持思考的只有 `off`；不认识的新强度读出时丢掉），以及能不能看图
/// （`nil` 是 Agent 没报，当作能）。`supportsFast` 与思考档同由运行时上报：Codex 读 `serviceTiers`，Pi 看模型的 Responses API；
/// 从 CuePad 切到不支持的模型会关闭 fast。Claude Code 的现有控制通道未确认能可靠切换，OpenCode 与 Grok Build 本次不接。
/// JSON 里 provider、id 与 name 平铺，强度叫 `thinking`、看图叫 `images`。
public struct ModelOption: Sendable, Equatable, Identifiable, Codable {
  public var key: ModelKey
  public var name: String
  public var thinkingLevels: [ThinkingLevel]
  public var acceptsImages: Bool?
  public var account: PiAccount?
  public var supportsFast: Bool
  public var id: ModelKey { key }

  public init(key: ModelKey, name: String, thinkingLevels: [ThinkingLevel], acceptsImages: Bool? = nil, account: PiAccount? = nil, supportsFast: Bool = false) {
    self.key = key
    self.name = name
    self.thinkingLevels = thinkingLevels
    self.acceptsImages = acceptsImages
    self.account = account
    self.supportsFast = supportsFast
  }

  private enum CodingKeys: String, CodingKey {
    case provider, id, name
    case thinking, images, account, supportsFast
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      key: ModelKey(provider: try c.decode(String.self, forKey: .provider), id: try c.decode(String.self, forKey: .id)),
      name: try c.decode(String.self, forKey: .name),
      thinkingLevels: try c.decode([String].self, forKey: .thinking).compactMap(ThinkingLevel.init(rawValue:)),
      acceptsImages: try c.decodeIfPresent(Bool.self, forKey: .images), account: try c.decodeIfPresent(PiAccount.self, forKey: .account),
      supportsFast: try c.decodeIfPresent(Bool.self, forKey: .supportsFast) ?? false)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key.provider, forKey: .provider)
    try c.encode(key.id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(thinkingLevels.map(\.rawValue), forKey: .thinking)
    try c.encodeIfPresent(acceptsImages, forKey: .images)
    try c.encodeIfPresent(account, forKey: .account)
    if supportsFast { try c.encode(true, forKey: .supportsFast) }
  }
}

public struct ModelState: Sendable, Equatable {
  public var model: ModelOption?
  public var thinking: Open<ThinkingLevel>?
  public var fast: Bool?
  public var models: [ModelOption]

  public init(model: ModelOption? = nil, thinking: Open<ThinkingLevel>? = nil, fast: Bool? = nil, models: [ModelOption] = []) {
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.models = models
  }
}

/// 会话的上下文余量：已用 token 与当前模型的上下文窗口（Pi 桥上报；Pi 在压缩后到下一次回答前不知道已用多少，`tokens` 为 nil）。
public struct ContextUsage: Sendable, Equatable, Codable {
  public var tokens: Int?
  public var window: Int
  public var compactAt: Int?

  public init(tokens: Int?, window: Int, compactAt: Int? = nil) {
    self.tokens = tokens
    self.window = window
    self.compactAt = compactAt
  }

  public var fraction: Double? {
    guard let tokens, window > 0 else { return nil }
    return min(1, Double(tokens) / Double(window))
  }
}

/// 斜杠命令的来源：Pi 内置里能在非 TUI 下执行的、扩展命令、提示词模板、skill。
public enum CommandSource: String, Sendable, CaseIterable, Codable {
  case builtin, `extension`, prompt, skill
}

public struct SlashCommand: Sendable, Equatable, Identifiable, Codable {
  public var name: String
  public var summary: String?
  public var source: Open<CommandSource>
  public var hint: String?
  public var id: String { name }

  public init(name: String, summary: String?, source: Open<CommandSource>, hint: String? = nil) {
    self.name = name
    self.summary = summary
    self.source = source
    self.hint = hint
  }
}

public enum SubagentPhase: String, Sendable, CaseIterable, Codable {
  case running, review, paused, done, failed, rejected, interrupted, idle
}

public struct SubagentState: Sendable, Equatable, Codable {
  public var name: String
  public var role: String
  public var phase: Open<SubagentPhase>
  public var action: String
  public var startedAt: Date?
  public var settledAt: Date?
  public var model: String?
  public var progressAt: Date?

  public init(
    name: String, role: String, phase: Open<SubagentPhase>, action: String = "", startedAt: Date? = nil, settledAt: Date? = nil,
    model: String? = nil, progressAt: Date? = nil
  ) {
    self.name = name
    self.role = role
    self.phase = phase
    self.action = action
    self.startedAt = startedAt
    self.settledAt = settledAt
    self.model = model
    self.progressAt = progressAt
  }

  var shape: SubagentState {
    var shape = self
    shape.action = ""
    shape.progressAt = nil
    return shape
  }

  private enum CodingKeys: String, CodingKey {
    case name, role, action, startedAt, settledAt, model, progressAt
    case phase = "state"
  }
}

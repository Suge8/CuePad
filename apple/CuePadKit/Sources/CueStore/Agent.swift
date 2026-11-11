import Foundation

/// 同步字段：其他版本写的不认识的值读作 `Open.unknown`；旧版本写的没有这一列，是 Pi。
public enum AgentKind: String, CaseIterable, Sendable, Identifiable, Codable {
  case pi
  case claudeCode = "claude"
  case codex
  case opencode
  case grok
  case dsh

  public var id: Self { self }

  /// 交出后收没收下只看会话文件里有没有这句话（App 的 `DeliveryConfirmation`，重开后接着核对也按它）：Pi 的回执先于写会话文件。
  public var confirmsFromHistory: Bool { self == .pi }

  public var name: String {
    switch self {
    case .pi: "Pi"
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    case .grok: "Grok Build"
    case .dsh: "DeepSeek Harness"
    }
  }

  /// CuePad 的 Pi 扩展设在它所在进程环境里的会话 id：用户在 CuePad 里看的那个会话。FireCode 子代理与它同进程，命令里的
  /// `PI_SESSION_ID` 是子代理自己的会话（CuePad 不列），所以 `cuepad show` 先认这个，子代理发的卡也落在用户看的对话里。
  public static let watchedSessionVariable = "CUEPAD_SESSION_ID"

  public var sessionVariable: String {
    switch self {
    case .pi: "PI_SESSION_ID"
    case .claudeCode: "CLAUDE_CODE_SESSION_ID"
    case .codex: "CODEX_THREAD_ID"
    case .opencode: "OPENCODE_SESSION_ID"
    case .grok: "GROK_SESSION_ID"
    case .dsh: "DSH_SESSION_ID"
    }
  }

  /// Claude Code、Codex、Grok Build 的模型名在它们自己的命名空间里（`opus`、`gpt-5.1`、`grok-4.6`），提供方就写成这家；Pi、OpenCode、dsh 的模型本身带提供方，为 nil。
  public var modelProvider: String? {
    switch self {
    case .claudeCode, .codex, .grok: rawValue
    case .pi, .opencode, .dsh: nil
    }
  }

  public func modelRef(_ key: ModelKey) -> String { modelProvider != nil ? key.id : "\(key.provider)/\(key.id)" }

  public func modelKey(_ ref: String) -> ModelKey? {
    let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2 { return ModelKey(provider: parts[0], id: parts[1]) }
    guard parts.count == 1, let modelProvider else { return nil }
    return ModelKey(provider: modelProvider, id: parts[0])
  }

  /// 读不出抛 `invalidModel`（Cue 写的 model）。
  public func requiredModelKey(_ ref: String) throws -> ModelKey {
    guard let key = modelKey(ref) else { throw CueStoreError.invalidModel(name) }
    return key
  }
}

/// 因家或因模型而异的几样：Mac 与手机按同一条规则从会话记录推出（不同步、不落库），执行端不另做判断。
/// 说话、停下、换模型、改名、斜杠命令、作答、结束每家都有：会话都是 CuePad 在后台托管的。
public struct AgentCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let images = AgentCapabilities(rawValue: 1 << 0)
  public static let retry = AgentCapabilities(rawValue: 1 << 1)
  /// 查订阅额度：只有 CuePad 的 Pi 扩展会查。一台 Mac 能不能答额度只看它上面有没有在线、带这一项的会话。
  public static let quota = AgentCapabilities(rawValue: 1 << 2)

  public static func of(_ agent: AgentKind, model: ModelOption?) -> AgentCapabilities {
    var capabilities: AgentCapabilities = agent == .pi ? [.images, .retry, .quota] : .images
    if model?.acceptsImages == false { capabilities.remove(.images) }
    return capabilities
  }
}

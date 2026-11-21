import Foundation

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

  public static let sessionVariables = [watchedSessionVariable] + allCases.map(\.sessionVariable)

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

  public func requiredModelKey(_ ref: String) throws -> ModelKey {
    guard let key = modelKey(ref) else { throw CueStoreError.invalidModel(name) }
    return key
  }
}

public struct AgentCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let images = AgentCapabilities(rawValue: 1 << 0)
  public static let retry = AgentCapabilities(rawValue: 1 << 1)
  public static let quota = AgentCapabilities(rawValue: 1 << 2)

  public static func of(_ agent: AgentKind, model: ModelOption?) -> AgentCapabilities {
    var capabilities: AgentCapabilities = agent == .pi ? [.images, .retry, .quota] : .images
    if model?.acceptsImages == false { capabilities.remove(.images) }
    return capabilities
  }
}

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
  public func confirmsFromHistory(hosted: Bool) -> Bool { self == .pi }

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

/// 只由 Agent 与会话在哪跑定：Mac 与手机按同一条规则从会话记录推出，执行端不另做判断。
public struct AgentCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let images = AgentCapabilities(rawValue: 1 << 0)
  public static let abort = AgentCapabilities(rawValue: 1 << 1)
  public static let model = AgentCapabilities(rawValue: 1 << 2)
  public static let rename = AgentCapabilities(rawValue: 1 << 3)
  public static let commands = AgentCapabilities(rawValue: 1 << 4)
  public static let answer = AgentCapabilities(rawValue: 1 << 5)
  public static let end = AgentCapabilities(rawValue: 1 << 6)
  public static let speak = AgentCapabilities(rawValue: 1 << 7)
  public static let retry = AgentCapabilities(rawValue: 1 << 8)
  /// 查订阅额度：只有 CuePad 的 Pi 扩展会查。一台 Mac 能不能答额度只看它上面有没有在线、带这一项的会话。
  public static let quota = AgentCapabilities(rawValue: 1 << 9)

  public static let all: AgentCapabilities = [.speak, .images, .abort, .model, .rename, .commands, .answer, .end]

  /// 在线时说不了话（没有 `.speak`）的只能在它的终端里说；在跑时说话要先停下这一轮，停不下（没有 `.abort`）就说不了。
  /// 只有终端里的 Claude Code 这样：CuePad 只能经它的收件箱说话，前台工具跑着时收件箱的话要等工具跑完才读到（`priority: "now"` 也一样），收件箱也没有停下这一轮的办法（Claude Code 2.1.299 实测与源码）。
  /// 界面的回复框、Cue 说话与 Mac 执行发话都只认这里；不排队，歇下再说。
  public func speakBlocked(in state: WorkState?, agent: AgentKind?) -> String? {
    if !contains(.speak), state != .ended {
      return String(localized: "终端里的 \(agent?.name ?? "Agent") 只能在终端里说话：CuePad 只看得到它在做什么")
    }
    guard state?.isTurnRunning == true, !contains(.abort) else { return nil }
    return String(localized: "终端里的 \(agent?.name ?? "Agent") 在跑，CuePad 打断不了它：在终端里按 Esc，或等它做完再说")
  }

  public static func of(_ agent: AgentKind, hosted: Bool, model: ModelOption?) -> AgentCapabilities {
    var capabilities = of(agent, hosted: hosted)
    if model?.acceptsImages == false { capabilities.remove(.images) }
    return capabilities
  }

  private static func of(_ agent: AgentKind, hosted: Bool) -> AgentCapabilities {
    if hosted { return agent == .pi ? .all.union([.retry, .quota]) : .all }
    switch agent {
    // dsh 只有 CuePad 托管的会话（它的 web 与桌面版的会话不接）
    case .pi: return .all.union([.retry, .quota])
    case .opencode, .dsh: return .all
    // 终端里的会话经它的收件箱说话与改名（只收文字）、经钩子作答、像 Ctrl-C 那样结束；停止这一轮、换模型、斜杠命令只有托管的能做
    case .claudeCode: return [.speak, .answer, .rename, .end]
    case .codex: return [.speak, .images, .abort, .model, .rename, .commands, .answer]
    // 终端里的会话只读跟读它的会话记录，CuePad 碰不到它的输入
    case .grok: return []
    }
  }
}

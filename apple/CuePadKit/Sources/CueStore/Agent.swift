import Foundation

/// CuePad 接入的 Agent。会话记录、投送请求与历史索引都带着它（同步字段，其他版本写的不认识的值读作 `Open.unknown`；
/// 旧版本写的没有这一列，是 Pi）。
public enum AgentKind: String, CaseIterable, Sendable, Identifiable, Codable {
  case pi
  case claudeCode = "claude"
  case codex
  case opencode

  public var id: Self { self }

  public var name: String {
    switch self {
    case .pi: "Pi"
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .opencode: "OpenCode"
    }
  }

  /// 这家模型的提供方（`PiModelKey.provider`），唯一的一处：Claude Code、Codex 的模型名在它们自己的命名空间里（`opus`、`gpt-5.1`），
  /// 提供方就写成这家；Pi、OpenCode 的模型本身带提供方（`provider/id`），为 nil。会话上报的模型、Cue 的可选清单、开工时只给了 id 的补全都按它。
  public var modelProvider: String? {
    switch self {
    case .claudeCode, .codex: rawValue
    case .pi, .opencode: nil
    }
  }
}

/// 从 CuePad 能对一个会话做什么（发文字总能做，不在其中）。只由 Agent 与会话在哪跑定：Mac 与手机按同一条规则从会话记录推出，
/// 界面据此只露出做得到的操作，执行端不另做判断。各家能力的出处见 CuePi README「接入 Agent」。
public struct AgentCapabilities: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// 发图片
  public static let images = AgentCapabilities(rawValue: 1 << 0)
  /// 马上说：在这一轮的下一步之前插进去（不打断在跑的工具）
  public static let steer = AgentCapabilities(rawValue: 1 << 1)
  /// 停止这一轮
  public static let abort = AgentCapabilities(rawValue: 1 << 2)
  /// 换模型与思考强度
  public static let model = AgentCapabilities(rawValue: 1 << 3)
  /// 改会话名
  public static let rename = AgentCapabilities(rawValue: 1 << 4)
  /// 斜杠命令
  public static let commands = AgentCapabilities(rawValue: 1 << 5)
  /// 回答它弹出的问题与权限确认
  public static let answer = AgentCapabilities(rawValue: 1 << 6)
  /// 结束会话
  public static let end = AgentCapabilities(rawValue: 1 << 7)

  public static let all: AgentCapabilities = [.images, .steer, .abort, .model, .rename, .commands, .answer, .end]

  /// `hosted`：会话在 CuePad 托管的进程里（没有终端界面），CuePad 掌握它的全部输入输出。
  /// 当前模型报了不能看图就不能发图片（没报的照 Agent 的能力）。
  public static func of(_ agent: AgentKind, hosted: Bool, model: PiModelOption?) -> AgentCapabilities {
    var capabilities = of(agent, hosted: hosted)
    if model?.acceptsImages == false { capabilities.remove(.images) }
    return capabilities
  }

  private static func of(_ agent: AgentKind, hosted: Bool) -> AgentCapabilities {
    if hosted { return .all }
    switch agent {
    case .pi, .opencode: return .all
    // 终端里的会话经它的收件箱插话与改名（只收文字）、经钩子作答、像 Ctrl-C 那样结束；停止这一轮、换模型、斜杠命令只有托管的能做
    case .claudeCode: return [.steer, .answer, .rename, .end]
    // 终端里的会话由 Codex 的常驻服务承载，经它的控制接口说话；作答经钩子
    case .codex: return [.images, .steer, .abort, .model, .rename, .commands, .answer]
    }
  }
}

/// Agent 钩子与 CuePad 之间的一次转发（Claude Code、Codex 的钩子命令是 `cuepad hook <agent>`）：钩子进程把 Agent 给的输入、
/// 自己的环境与所在终端整理成一行发到 CuePad 的钩子 socket（`socketPath`），等 CuePad 回一行（Agent 要的输出，可以为空）
/// 或关掉连接，再把回的原样写到标准输出。CuePad 没在运行（连不上）时什么也不输出、立即退出，Agent 照常往下走。
public struct AgentHookEnvelope: Codable, Sendable, Equatable {
  public var agent: AgentKind
  /// Agent 写到钩子标准输入的 JSON 原文
  public var input: Data
  /// 钩子进程环境里与会话相关的变量（`relayedPrefixes`）
  public var environment: [String: String]
  /// Agent 进程（Claude Code 给 `CLAUDE_PID`，否则是钩子的父进程）与它的控制终端
  public var pid: Int32
  public var tty: String?

  public static let relayedPrefixes = ["CLAUDE_", "CODEX_", "CUEPAD_", "TERM_PROGRAM", "TMUX", "__CFBundleIdentifier"]

  public init(agent: AgentKind, input: Data, environment: [String: String], pid: Int32, tty: String?) {
    self.agent = agent
    self.input = input
    self.environment = environment
    self.pid = pid
    self.tty = tty
  }

  /// Pi 会话与钩子 socket 所在的目录（`CUEPAD_PI_SOCKET_DIR`，缺省 `/tmp/cuepad-<uid>`）：`sun_path` 上限 104 字节，所以不用 `$TMPDIR`；
  /// Pi 扩展用同一缺省值。隔离运行（开发构建，`isolatedLibrary` 是它的资料库目录）没给时按资料库目录另起一个：缺省目录是正式版的，
  /// 用它桥会连上用户正在跑的会话，钩子 socket 也会把正式版的抢走。
  public static func socketDirectory(environment: [String: String], isolatedLibrary: URL? = nil) -> URL {
    if let given = environment["CUEPAD_PI_SOCKET_DIR"], !given.isEmpty { return URL(filePath: given, directoryHint: .isDirectory) }
    let suffix = isolatedLibrary.map { "-" + DeterministicID.uuid($0.standardizedFileURL.path).uuidString.prefix(8).lowercased() } ?? ""
    return URL(filePath: "/tmp/cuepad-\(getuid())\(suffix)", directoryHint: .isDirectory)
  }

  /// 钩子 socket。不带 `.sock` 后缀：Pi 桥扫目录时不把它当 Pi 会话去连。
  public static func socketPath(in directory: URL) -> URL { directory.appending(path: "agent-hooks") }

  public static func socketPath(environment: [String: String]) -> URL { socketPath(in: socketDirectory(environment: environment)) }
}

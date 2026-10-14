#if os(macOS)
import CueStore
import Foundation

/// 终端信息，来自扩展 hello 里的环境变量；供"跳到该会话所在终端"使用。
public struct PiTerminal: Sendable, Equatable {
    public var tty: String?
    public var program: String?
    public var bundleID: String?
    public var tmuxPane: String?
    public var tmuxSocketPath: String?

    public init(tty: String? = nil, program: String? = nil, bundleID: String? = nil,
                tmuxPane: String? = nil, tmuxSocketPath: String? = nil) {
        self.tty = tty
        self.program = program
        self.bundleID = bundleID
        self.tmuxPane = tmuxPane
        self.tmuxSocketPath = tmuxSocketPath
    }

    init(tty: String?, environment env: [String: String]) {
        self.init(
            tty: tty,
            program: env["TERM_PROGRAM"],
            bundleID: env["__CFBundleIdentifier"],
            tmuxPane: env["TMUX_PANE"],
            // TMUX=<socket路径>,<server pid>,<session>
            tmuxSocketPath: env["TMUX"].flatMap { $0.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) }
        )
    }
}

/// 一个活着的 Agent 会话（一个进程里的一个会话）。状态与随会话同步的各块值直接用 CueStore 的类型：桥解码出来什么样，记录器就原样写什么样。
public struct PiSession: Identifiable, Sendable, Equatable {
    /// `<sessionId>.<pid>`：同一会话被两个进程同时打开时也唯一；Pi 的等于 socket 文件名去掉 `.sock`
    public let id: String
    public let sessionID: String
    public let agent: AgentKind
    /// 首条消息落盘前该文件还不存在；`--no-session` 时为 nil，OpenCode 的会话在它的数据库里，也为 nil。只有测试读（读会话文件核对对话）
    public let sessionFile: URL?
    /// 承载这个会话的进程：Pi、Claude Code 是会话自己的进程；Codex 是承载终端会话的常驻服务，OpenCode 是它的后台服务（同一进程承载多个会话）
    public let pid: Int32
    public let cwd: URL
    public let terminal: PiTerminal
    /// 该会话加载的 Pi 扩展版本（其他 Agent 为 0）；只有测试读（核对 /reload 后载入的是随包的扩展）
    public let extensionVersion: Int
    public internal(set) var state: PiWorkState
    /// 一句话说明（同步记录的 `detail`）：工具名与调用目标、等你回答的弹窗标题、出错的摘要；其余状态为 nil
    public internal(set) var detail: String? = nil
    /// 出错时 Pi 上报的原文（会话行悬停看）；`detail` 里是摘要
    public internal(set) var errorMessage: String? = nil
    /// 进入当前粗状态（工作中、等你确认、出错、空闲）的时间：思考、工具、等子代理之间切换不变
    public internal(set) var stateSince: Date
    /// 这段连续处理开始的时间：离开空闲起，到彻底歇下（自己歇下且没有子代理在飞）为止，中间等你确认也不断；空闲、出错时为 nil
    public internal(set) var busySince: Date? = nil
    /// `/name` 设的会话名
    public internal(set) var name: String? = nil
    /// 首条用户消息的开头
    public internal(set) var firstMessage: String? = nil
    /// 正在等你回答的弹窗；不在等待时为 nil
    public internal(set) var question: PiQuestion? = nil
    /// CuePad 开的新会话带着发起方的认领标识（`PiLaunch.token`，经环境变量 `CUEPAD_LAUNCH_TOKEN` 交给扩展）；其余会话为 nil
    public internal(set) var launchToken: String? = nil
    /// 本会话在同一进程里开的子代理（FireCode 的子代理是进程内子会话，不作为独立会话出现）
    public internal(set) var subagents: [PiSubagentState] = []
    /// CuePad 在后台托管的 Pi（RPC 模式，没有终端界面）：启动时经环境变量 `CUEPAD_HOSTED` 告诉扩展，扩展在 hello 里带回
    public internal(set) var hosted = false
    /// 当前模型、思考强度与可以换成的模型；未选模型时 `model` 与 `thinking` 为 nil
    public internal(set) var model: PiModelOption? = nil
    public internal(set) var thinking: Open<PiThinkingLevel>? = nil
    public internal(set) var availableModels: [PiModelOption] = []
    /// 上下文余量：没有模型时为 nil
    public internal(set) var context: PiContextUsage? = nil
    /// 此刻能用的斜杠命令
    public internal(set) var commands: [PiSlashCommand] = []

    public var modelState: PiModelState { PiModelState(model: model, thinking: thinking, models: availableModels) }

    /// 从 CuePad 能对它做什么（与同步记录上的 `PiSessionState.capabilities` 同一条规则）。
    public var capabilities: AgentCapabilities { .of(agent, hosted: hosted) }

    /// 留下了对话：会话文件已经落盘（第一条消息之前不建文件）；OpenCode 的会话一建就在它的数据库里。下线时据此决定进不进历史。
    public var spoke: Bool {
        agent == .opencode || sessionFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    /// 会话的显示名，规则见 `PiSessionName`。
    public var displayName: String {
        PiSessionName.display(name: name, firstMessage: firstMessage, folder: cwd.lastPathComponent)
    }
}

/// Pi 会话显示名的唯一规则（活动会话与历史会话共用），与 Pi 自己的会话列表一致：
/// `/name` 设的名字 → 会话文件里第一条有文字的用户消息 → 工作目录名。控制字符换成空格并去掉首尾空白，所以是单行。
public enum PiSessionName {
    /// 首条用户消息只用来当单行显示名：只取开头这么多字符（扩展的 `FIRST_MESSAGE_LIMIT` 与之相同）。
    public static let firstMessageLimit = 200

    public static func display(name: String?, firstMessage: String?, folder: String) -> String {
        [name, firstMessage.map(withoutImageNotes)].lazy.compactMap { $0.map(singleLine) }.first { !$0.isEmpty } ?? folder
    }

    /// 你的一句话当首条消息记下的样子：去掉首尾空白后的开头 `firstMessageLimit` 个字符；没有文字为 nil（接着看下一条）。
    /// 与 Pi 自己的会话列表一致，扩展投进来的机器消息也算。
    public static func firstMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(firstMessageLimit))
    }

    /// 扩展或 Agent 自己投进会话的机器消息：整条文字只由一个或多个 `<名字>\n…\n</名字>` 块组成（如 FireCode 的
    /// `<firecode_master_event>`、Codex 子代理的通知）。块正文止于第一个同名闭合标签：块与块之间夹着真人文字时整条不匹配。
    /// 它们不进对话、不是提问，只开始一轮。
    public static func isMachineMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return machineMessage.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static let machineMessage = try! NSRegularExpression(pattern: #"^(?:<([A-Za-z][\w.-]*)>\n(?:(?!\n</\1>)[\s\S])*\n</\1>\s*)+$"#)

    /// Pi 把图片缩小或转格式后，在你的话末尾加给模型看的说明行（`[Image: original …]`、`[Image converted from …]`）：CuePad 里一律不显示，
    /// 会话名、对话、摘要都经这里去掉。按行首认（扩展给的首条消息被截断时说明行可能不完整），只去末尾连续的说明行（说明行后面的空行不挡），其余原样。
    public static func withoutImageNotes(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard let last = lines.last, isImageNote(last) else { return text }
        while let last = lines.last, isImageNote(last) { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImageNote(_ line: Substring) -> Bool {
        line.hasPrefix("[Image: original ") || line.hasPrefix("[Image converted from ")
    }

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PiSessionEndReason: Sendable, Equatable {
    /// 连接断开且没有告别：进程被强杀/崩溃
    case disconnected
    /// 扩展先发了 `bye`：`quit`（退出）/`new`/`resume`/`fork`/`reload`。`undelivered` 是扩展受理了、却没来得及交给 Pi 的话
    /// （手动压缩期间留着的，见 `send`）的投送请求 id：它们没送到
    case closed(reason: String, undelivered: [String] = [])
}

public enum PiSessionChange: Sendable, Equatable {
    case appeared(PiSession)
    case stateChanged(PiSession, from: PiWorkState)
    /// 会话名、首条消息或近况变了（`displayName` 可能随之改变）
    case infoChanged(PiSession)
    case ended(PiSession, reason: PiSessionEndReason)
    /// 消息损坏（读不出会话或之后的消息格式不对）；连接已关闭，不会出现在 `sessions` 里。协议版本不同的会话不在此列，它以 `.incompatible` 状态出现
    case incompatible(id: String, detail: String)
    /// 某个会话的扩展观测到订阅额度（回复里带回的，或 `PiBridge.refreshQuota` 查到的）：属于账号，记到 `AccountQuota` 上
    case quota(QuotaReport)
}

public enum PiQueueMode: String, Sendable, Equatable {
    /// 当前轮工具执行完后、下一次模型调用前送达
    case steer
    /// 等 agent 完全停下后再处理
    case followUp
}

public struct PiImage: Sendable, Equatable {
    public var mimeType: String
    public var data: Data
    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

public struct PiMessage: Sendable, Equatable {
    public var text: String
    public var images: [PiImage]
    /// 会话正忙时的入队方式；缺省 `followUp`。空闲时忽略。
    public var whenBusy: PiQueueMode?
    /// CuePad 投送请求的 id：扩展把它写进会话文件里这条消息（`cuepadDelivery`），对话据此认出是哪条请求送进来的（扩展 v12 起）
    public var deliveryID: String?
    public init(text: String, images: [PiImage] = [], whenBusy: PiQueueMode? = nil, deliveryID: String? = nil) {
        self.text = text
        self.images = images
        self.whenBusy = whenBusy
        self.deliveryID = deliveryID
    }
}

/// 扩展受理消息时会话的状态。`ack` 只表示"已受理"，不代表模型成功。
public enum PiDelivery: Sendable, Equatable {
    case immediate
    case queued(PiQueueMode)
}

public enum PiBridgeError: Error, Equatable {
    /// socket 目录不是"属于当前用户、权限 0700 的目录"
    case insecureSocketDirectory(String)
    case socketDirectoryTooLong
    case unknownSession(String)
    /// 等 ack 时连接断了
    case sessionEnded
    case ackTimeout
    /// 扩展拒绝：`empty` / `bad_request` / `failed: …`；斜杠命令还有 `unknown_command`（清单里没有的名字）、`missing_argument`（必填参数没给）；作答时还有 `no_prompt`（没有在等的弹窗）、`stale_prompt`（标识不是正在等的那个）、
    /// `bad_answer`（答案类型或选项不对）；配置时还有 `unknown_model`（模型不在 Pi 的模型表里）、`no_auth`（该提供方没配好密钥）
    case rejected(String)
    /// 会话的扩展协议版本与 CuePad 不同（见 `PiWorkState.incompatible`），不发命令
    case incompatibleExtension
    /// 这个 Agent 的这类会话做不到（见 `AgentCapabilities`）
    case unsupported
}

extension PiBridgeError: LocalizedError {
    private static let failedPrefix = "failed: "

    public var errorDescription: String? {
        switch self {
        case .insecureSocketDirectory(let path): "Pi 连接目录 \(path) 不安全：必须属于当前用户且权限为 0700"
        case .socketDirectoryTooLong: "Pi 连接目录的路径太长"
        case .unknownSession: "这个 Agent 会话已经结束"
        case .incompatibleExtension: "这个会话正在终端里运行旧版扩展，在终端里执行 /reload 后再发"
        case .unsupported: "这个 Agent 会话不支持这样操作"
        case .sessionEnded: "发送途中 Agent 会话结束了"
        case .ackTimeout: "Agent 没有及时确认收到，请确认会话仍在运行"
        case .rejected("no_prompt"), .rejected("stale_prompt"): "这个问题已经答过了，或 Agent 已经不在等这个问题"
        case .rejected("bad_answer"): "答案和问题对不上（选项不在列表里，或类型不对）"
        case .rejected("unknown_model"): "这台 Mac 上的 Pi 里找不到这个模型"
        case .rejected("no_auth"): "这个模型的提供方在这台 Mac 上还没有登录或配置密钥"
        case .rejected("unknown_command"): "这个 Agent 会话里没有这个命令（可能已经被移除，或是只能在终端里用）"
        case .rejected("missing_argument"): "这个命令需要带上参数"
        case .rejected("compacting"): "Agent 正在压缩上下文，压完再发这个命令"
        // 扩展执行时出错（`failed: <原因>`）：原因就是要说的话
        case .rejected(let reason) where reason.hasPrefix(Self.failedPrefix): String(reason.dropFirst(Self.failedPrefix.count))
        case .rejected(let reason): "Agent 没有接受：\(reason)"
        }
    }
}
#endif

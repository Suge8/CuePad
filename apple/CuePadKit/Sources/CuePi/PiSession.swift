#if os(macOS)
import Foundation

/// 扩展上报的会话实时状态（只在内存，来自连接）。
public enum PiAgentState: Sendable, Equatable {
    case idle
    case thinking
    case outputting
    /// `name` 是最近开始的工具，`running` 是并行执行中的全部工具名，`detail` 是该工具调用的一句话摘要（可空）
    case tool(name: String, running: [String], detail: String? = nil)
    /// 自己这轮已经歇下，还有子代理在飞（FireCode 的在飞数）：仍在处理
    case delegating
    /// 扩展发起的 `ctx.ui` 弹窗（Pi 没有内置工具审批）
    case waitingUser(kind: String?, title: String?)
    /// 一轮结束且 Pi 不会再自动继续（`agent_settled`）
    case done(aborted: Bool)
    case error(message: String)
    /// 扩展的协议版本与 CuePad 不同（升级前开的 Pi 还在跑旧扩展）：进程在、会话没死，但读不到状态、也不能发命令，要重开 Pi
    case incompatible
}

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

/// 一个活着的 Pi 会话（一个进程里的一个会话）。
public struct PiSession: Identifiable, Sendable, Equatable {
    /// `<sessionId>.<pid>`：同一会话被两个进程同时打开时也唯一，等于 socket 文件名去掉 `.sock`
    public let id: String
    public let sessionID: String
    /// 首条消息落盘前该文件还不存在；`--no-session` 时为 nil
    public let sessionFile: URL?
    public let pid: Int32
    public let cwd: URL
    /// Pi 运行模式：`tui` / `rpc` / …
    public let mode: String
    public let terminal: PiTerminal
    /// 该会话加载的扩展版本；低于 `PiExtensionBundle.version` 说明需要重启会话才能用上新扩展
    public let extensionVersion: Int
    public internal(set) var state: PiAgentState
    /// 进入当前粗状态（工作中、等你确认、出错、空闲）的时间：思考、工具、等子代理之间切换不变。扩展 v6 起，旧扩展是细状态的切换时间
    public internal(set) var stateSince: Date
    /// 这段连续处理开始的时间：离开空闲起，到彻底歇下（自己歇下且没有子代理在飞）为止，中间等你确认也不断；
    /// 空闲、出错时为 nil。扩展 v6 起，旧扩展为 nil
    public internal(set) var busySince: Date? = nil
    /// `/name` 设的会话名（扩展 v3 起上报）
    public internal(set) var name: String? = nil
    /// 首条用户消息的开头（扩展 v3 起上报）
    public internal(set) var firstMessage: String? = nil
    /// 正在等你回答的弹窗；不在等待时为 nil
    public internal(set) var question: PiPrompt? = nil
    /// CuePad 开的新会话带着发起方的认领标识（`PiLaunch.start` 的 token，经环境变量 `CUEPAD_LAUNCH_TOKEN` 交给扩展）；
    /// 其余会话为 nil
    public internal(set) var launchToken: String? = nil
    /// 本会话在同一进程里开的子代理（扩展 v5 起；FireCode 的子代理是进程内子会话，不作为独立会话出现）
    public internal(set) var subagents: [PiSubagent] = []
    /// CuePad 在后台托管的 Pi（RPC 模式，没有终端界面）：启动时经环境变量 `CUEPAD_HOSTED` 告诉扩展，扩展在 hello 里带回
    public internal(set) var hosted = false
    /// 当前模型、思考强度（`off` … `max`）与可以换成的模型（协议 v2、扩展 v13 起）；未选模型时 `model` 与 `thinking` 为 nil
    public internal(set) var model: PiModel? = nil
    public internal(set) var thinking: String? = nil
    public internal(set) var availableModels: [PiModel] = []

    public var hasOutdatedExtension: Bool { extensionVersion < PiExtensionBundle.version }

    /// 会话的显示名，规则见 `PiSessionName`。旧扩展不报名字与消息，显示工作目录名。
    public var displayName: String {
        PiSessionName.display(name: name, firstMessage: firstMessage, folder: cwd.lastPathComponent)
    }
}

/// 一个模型的标识：提供方加模型 id（同一个 id 可以出自不同提供方）。
public struct PiModelRef: Sendable, Hashable, Equatable {
    public var provider: String
    public var id: String

    public init(provider: String, id: String) {
        self.provider = provider
        self.id = id
    }
}

/// 会话可用的一个模型：显示名与它支持的思考强度（Pi 的 `getSupportedThinkingLevels`：不支持思考的只有 `off`）。
public struct PiModel: Sendable, Equatable, Decodable {
    public var provider: String
    public var id: String
    public var name: String
    public var thinkingLevels: [String]

    public var ref: PiModelRef { PiModelRef(provider: provider, id: id) }

    public init(provider: String, id: String, name: String, thinkingLevels: [String]) {
        self.provider = provider
        self.id = id
        self.name = name
        self.thinkingLevels = thinkingLevels
    }

    private enum CodingKeys: String, CodingKey {
        case provider, id, name
        case thinkingLevels = "thinking"
    }
}

/// 等你回答的弹窗（扩展 v7 起结构化；旧扩展只有文案，`id` 为 nil、`kind` 为空）。
public struct PiPrompt: Sendable, Equatable, Decodable {
    /// 这次弹窗的标识，从 CuePad 作答时带上；nil 表示只能在 Pi 里答（editor、custom 弹窗，或旧扩展）
    public var id: String?
    /// `confirm` / `select` / `text`，以及只能在 Pi 里答的 `editor`、`custom`
    public var kind: String
    /// 标题与说明（确认框），换行分隔，≤500 字符
    public var text: String
    /// 选择框的选项（原文，作答时按原文回传）
    public var options: [String]

    public init(id: String?, kind: String, text: String, options: [String] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case id, kind, text, options }

    public init(from decoder: any Decoder) throws {
        // 扩展 v4–v6 上报的是一段文字
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(id: nil, kind: "", text: legacy)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id), kind: try c.decode(String.self, forKey: .kind),
            text: try c.decode(String.self, forKey: .text), options: try c.decodeIfPresent([String].self, forKey: .options) ?? [])
    }
}

/// 对弹窗的回答：选择框选一项（原文）、确认框答是或否、输入框填文字。
public enum PiPromptAnswer: Sendable, Equatable {
    case option(String)
    case confirmed(Bool)
    case text(String)
}

/// 父会话里的一个子代理：名字与此刻在干什么。
public struct PiSubagent: Sendable, Equatable, Decodable {
    public enum Activity: Sendable, Equatable {
        case working, waitingForUser, idle, error
    }

    public var name: String
    /// 扩展上报的状态种类（同 `state.kind`）
    public var kind: String

    public init(name: String, kind: String) {
        self.name = name
        self.kind = kind
    }

    public var activity: Activity {
        switch kind {
        case "thinking", "outputting", "tool", "delegating": .working
        case "waiting_user": .waitingForUser
        case "error": .error
        default: .idle
        }
    }
}

/// Pi 会话显示名的唯一规则（活动会话与历史会话共用），与 Pi 自己的会话列表一致：
/// `/name` 设的名字 → 会话文件里第一条有文字的用户消息 → 工作目录名。控制字符换成空格并去掉首尾空白，所以是单行。
public enum PiSessionName {
    /// 首条用户消息只用来当单行显示名：只取开头这么多字符（扩展的 `FIRST_MESSAGE_LIMIT` 与之相同）。
    public static let firstMessageLimit = 200

    public static func display(name: String?, firstMessage: String?, folder: String) -> String {
        [name, firstMessage].lazy.compactMap { $0.map(singleLine) }.first { !$0.isEmpty } ?? folder
    }

    private static func singleLine(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PiSessionEndReason: Sendable, Equatable {
    /// 连接断开且没有告别：进程被强杀/崩溃
    case disconnected
    /// 扩展先发了 `bye`：`quit`（退出）/`new`/`resume`/`fork`/`reload`
    case closed(reason: String)
}

public enum PiSessionChange: Sendable, Equatable {
    case appeared(PiSession)
    case stateChanged(PiSession, from: PiAgentState)
    /// 会话名、首条消息或近况变了（`displayName` 可能随之改变）
    case infoChanged(PiSession)
    case ended(PiSession, reason: PiSessionEndReason)
    /// 消息损坏（读不出会话或之后的消息格式不对）；连接已关闭，不会出现在 `sessions` 里。协议版本不同的会话不在此列，它以 `.incompatible` 状态出现
    case incompatible(id: String, detail: String)
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
    /// 扩展拒绝：`empty` / `bad_request` / `failed: …`；作答时还有 `no_prompt`（没有在等的弹窗）、`stale_prompt`（标识不是正在等的那个）、
    /// `bad_answer`（答案类型或选项不对）；配置时还有 `unknown_model`（模型不在 Pi 的模型表里）、`no_auth`（该提供方没配好密钥）
    case rejected(String)
    /// 会话的扩展协议版本与 CuePad 不同（见 `PiAgentState.incompatible`），不发命令
    case incompatibleExtension
}

extension PiBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureSocketDirectory(let path): "Pi 连接目录 \(path) 不安全：必须属于当前用户且权限为 0700"
        case .socketDirectoryTooLong: "Pi 连接目录的路径太长"
        case .unknownSession: "这个 Agent 会话已经结束"
        case .incompatibleExtension: "这个会话正在终端里运行旧版扩展，重开 Pi 后再发"
        case .sessionEnded: "发送途中 Agent 会话结束了"
        case .ackTimeout: "Agent 没有及时确认收到，请确认会话仍在运行"
        case .rejected("no_prompt"), .rejected("stale_prompt"): "这个问题已经答过了，或 Agent 已经不在等这个问题"
        case .rejected("bad_answer"): "答案和问题对不上（选项不在列表里，或类型不对）"
    case .rejected("unknown_model"): "这台 Mac 上的 Pi 里找不到这个模型"
    case .rejected("no_auth"): "这个模型的提供方在这台 Mac 上还没有登录或配置密钥"
        case .rejected(let reason): "Agent 拒绝了这条消息：\(reason)"
        }
    }
}
#endif

#if os(macOS)
import Foundation

/// 扩展上报的会话实时状态（只在内存，来自连接）。
public enum PiAgentState: Sendable, Equatable {
    case idle
    case thinking
    case outputting
    /// `name` 是最近开始的工具，`running` 是并行执行中的全部工具名，`detail` 是该工具调用的一句话摘要（可空）
    case tool(name: String, running: [String], detail: String? = nil)
    /// 扩展发起的 `ctx.ui` 弹窗（Pi 没有内置工具审批）
    case waitingUser(kind: String?, title: String?)
    /// 一轮结束且 Pi 不会再自动继续（`agent_settled`）
    case done(aborted: Bool)
    case error(message: String)
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
    public let model: String?
    public let terminal: PiTerminal
    /// 该会话加载的扩展版本；低于 `PiExtensionBundle.version` 说明需要重启会话才能用上新扩展
    public let extensionVersion: Int
    public internal(set) var state: PiAgentState
    public internal(set) var stateSince: Date

    public var hasOutdatedExtension: Bool { extensionVersion < PiExtensionBundle.version }
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
    case ended(PiSession, reason: PiSessionEndReason)
    /// 连上了但协议不兼容（扩展过新/过旧或消息损坏）；连接已关闭，不会出现在 `sessions` 里
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
    public init(text: String, images: [PiImage] = [], whenBusy: PiQueueMode? = nil) {
        self.text = text
        self.images = images
        self.whenBusy = whenBusy
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
    /// 扩展拒绝：`empty` / `bad_request` / `failed: …`
    case rejected(String)
}

extension PiBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureSocketDirectory(let path): "Pi 连接目录 \(path) 不安全：必须属于当前用户且权限为 0700"
        case .socketDirectoryTooLong: "Pi 连接目录的路径太长"
        case .unknownSession: "这个 Pi 会话已经结束"
        case .sessionEnded: "发送途中 Pi 会话结束了"
        case .ackTimeout: "Pi 没有及时确认收到，请确认会话仍在运行"
        case .rejected(let reason): "Pi 拒绝了这条消息：\(reason)"
        }
    }
}
#endif

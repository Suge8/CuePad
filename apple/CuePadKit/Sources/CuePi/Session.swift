#if os(macOS)
import CueStore
import Foundation

/// 来自扩展 hello 里的环境变量。
public struct TerminalIdentity: Sendable, Equatable {
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

    static func controllingTerminal(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32(bitPattern: -1),
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty == "??" ? nil : tty
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

/// 状态与随会话同步的各块值直接用 CueStore 的类型：桥解码出来什么样，记录器就原样写什么样。
public struct Session: Identifiable, Sendable, Equatable {
    /// `<sessionId>.<pid>`：同一会话被两个进程同时打开时也唯一；Pi 的等于 socket 文件名去掉 `.sock`
    public let id: String
    public let sessionID: String
    public let agent: AgentKind
    /// 首条消息落盘前该文件还不存在；`--no-session` 时为 nil，OpenCode 的会话在它的数据库里，也为 nil。
    public let sessionFile: URL?
    /// 承载这个会话的进程：Pi、Claude Code 是会话自己的进程；Codex 是承载终端会话的常驻服务，OpenCode 是它的后台服务（同一进程承载多个会话）
    public let pid: Int32
    public let cwd: URL
    /// 启动时从会话列表补上的会话没有终端的环境变量，第一次钩子才带来
    public internal(set) var terminal: TerminalIdentity
    public internal(set) var state: WorkState
    /// CuePad 读不懂这一版扩展（`PiWire.reads`）。这段时间读不到它在做什么（`state` 只是填的歇着）、也发不进命令；
    /// 同步记录不写、界面不换上桥上的状态，都照它最后一次读到的样子。
    public internal(set) var upgrading = false
    /// 一句话说明（同步记录的 `detail`）：工具名与调用目标、等你回答的弹窗标题、出错的摘要；其余状态为 nil
    public internal(set) var detail: String? = nil
    /// 出错时 Pi 上报的原文；`detail` 里是摘要
    public internal(set) var errorMessage: String? = nil
    /// 出错的种类（同步记录的 `SessionState.failure`）：只按原文归一次类（`ErrorSummary.failure`）
    public var failure: FailureKind? { state == .error ? ErrorSummary(errorMessage ?? "").failure : nil }
    public internal(set) var stateSince: Date
    public internal(set) var busySince: Date? = nil
    /// Pi 由扩展报（每次模型回合开始），其余由接入记（`SessionFacts.startTurn(at:)`）
    public internal(set) var turnStartedAt: Date? = nil
    /// `/name` 设的会话名
    public internal(set) var name: String? = nil
    public internal(set) var firstMessage: String? = nil
    public internal(set) var question: Question? = nil
    /// 经环境变量 `CUEPAD_LAUNCH_TOKEN` 交给扩展（`LaunchRequest.token`）；其余会话为 nil
    public internal(set) var launchToken: String? = nil
    /// FireCode 的子代理是进程内子会话，不作为独立会话出现
    public internal(set) var subagents: [SubagentState] = []
    /// CuePad 在后台托管的 Pi（RPC 模式，没有终端界面）：启动时经环境变量 `CUEPAD_HOSTED` 告诉扩展，扩展在 hello 里带回
    public internal(set) var hosted = false
    /// 见 `AgentKind.confirmsFromHistory`
    public var confirmsFromHistory: Bool { agent.confirmsFromHistory(hosted: hosted) }
    /// 未选模型时 `model` 与 `thinking` 为 nil
    public internal(set) var model: ModelOption? = nil
    public internal(set) var thinking: Open<ThinkingLevel>? = nil
    public internal(set) var fast: Bool? = nil
    public internal(set) var availableModels: [ModelOption] = []
    /// 只用来决定保留哪些额度记录，不存不同步
    public internal(set) var proofs: [PiProof] = []
    /// 上下文余量：没有模型时为 nil
    public internal(set) var context: ContextUsage? = nil
    public internal(set) var commands: [SlashCommand] = []

    public var modelState: ModelState { ModelState(model: model, thinking: thinking, fast: fast, models: availableModels) }

    public var capabilities: AgentCapabilities { .of(agent, hosted: hosted, model: model) }

    var carried: (state: WorkState, times: SessionTimes) { (state, SessionTimes(stateSince: stateSince, busySince: busySince)) }

    /// 第一条消息之前不建会话文件；不用会话文件的（OpenCode）一建就算。
    public var spoke: Bool {
        agent.facts.sessionFiles == nil || sessionFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    /// 标题与项目要查库，由 `SessionMirror` 定好交进来。
    func snapshot(title: String, projectID: UUID?) -> SessionSnapshot {
        var snapshot = SessionSnapshot(sessionID: sessionID, state: state, times: SessionTimes(stateSince: stateSince, busySince: busySince))
        snapshot.detail = detail
        snapshot.failure = failure
        snapshot.title = title
        snapshot.directory = cwd.path(percentEncoded: false)
        snapshot.projectID = projectID
        snapshot.question = question
        snapshot.turnStartedAt = turnStartedAt
        snapshot.launchToken = launchToken
        snapshot.hosted = hosted
        snapshot.subagents = subagents
        snapshot.modelState = modelState
        snapshot.context = context
        snapshot.commands = commands
        snapshot.agent = agent
        snapshot.process = SessionProcess.running(pid: pid)
        return snapshot
    }

    public var displayName: String {
        SessionName.display(name: name, firstMessage: firstMessage, folder: cwd.lastPathComponent)
    }
}

/// Pi 会话显示名的唯一规则（活动会话与历史会话共用），与 Pi 自己的会话列表一致。
public enum SessionName {
    /// 首条用户消息只用来当单行显示名：只取开头这么多字符（扩展的 `FIRST_MESSAGE_LIMIT` 与之相同）。
    public static let firstMessageLimit = 200

    public static func display(name: String?, firstMessage: String?, folder: String) -> String {
        [name, firstMessage.map { SkillCall.shown(withoutImageNotes($0)) }].lazy
            .compactMap { $0.map { singleLine(AttachmentFiles.namingAgentLines(in: $0)) } }.first { !$0.isEmpty } ?? folder
    }

    /// 没有文字为 nil（接着看下一条）。与 Pi 自己的会话列表一致，扩展投进来的机器消息也算。
    public static func firstMessage(_ text: String) -> String? {
        let trimmed = SkillCall.shown(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(firstMessageLimit))
    }


    /// Pi 把图片缩小或转格式后，在你的话末尾加给模型看的说明行（`[Image: original …]`、`[Image converted from …]`）：CuePad 里一律不显示，
    /// 会话名、对话、摘要都经这里去掉。按行首认：扩展给的首条消息被截断时说明行可能不完整。
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

public enum SessionEndReason: Sendable, Equatable {
    /// 连接断开且没有告别：进程被强杀/崩溃
    case disconnected
    /// 扩展先发了 `bye`：`quit`（退出）/`new`/`resume`/`fork`/`reload`
    case closed(reason: String)

    /// 重新载入扩展（/reload、扩展自己换上新版本）：同一进程随即在同一路径以新扩展连回来，会话没有结束
    public static let reload = SessionEndReason.closed(reason: "reload")
}

public enum SessionChange: Sendable, Equatable {
    case appeared(Session)
    case stateChanged(Session, from: WorkState)
    case infoChanged(Session)
    case ended(Session, reason: SessionEndReason)
    /// 消息损坏；连接已关闭，不会出现在 `sessions` 里。读不懂的扩展不在此列（`Session.upgrading`）
    case incompatible(id: String, detail: String)
    /// 属于账号，记到 `AccountQuota` 上
    case quota(QuotaReport)
}

public struct MessageImage: Sendable, Equatable {
    public var mimeType: String
    public var data: Data
    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

/// Cue 的发送只获准接管已确认属于它的那一轮；实际派发时重新核对，不把旧快照当打断许可。
public enum SendPolicy: Sendable, Equatable {
    case user
    case cue(deliveryID: String?, turnStartedAt: Date?)
}

public struct SessionMessage: Sendable, Equatable {
    public var text: String
    public var images: [MessageImage]
    /// CuePad 投送请求的 id：扩展把它写进会话文件里这条消息（`cuepadDelivery`），对话据此认出是哪条请求送进来的（扩展 v12 起）
    public var deliveryID: String?
    public var policy: SendPolicy
    public init(text: String, images: [MessageImage] = [], deliveryID: String? = nil, policy: SendPolicy = .user) {
        self.text = text
        self.images = images
        self.deliveryID = deliveryID
        self.policy = policy
    }
}

public enum BridgeError: Error, Equatable {
    case insecureSocketDirectory(String)
    case socketDirectoryTooLong
    case unknownSession(String)
    /// 已交出后等 ack 时连接断了：结果未知，不是未接受的证明。
    case sessionEnded
    /// 未及时观察到确认，可能已经执行；不能据此自动重投。
    case ackTimeout
    /// `unconfirmed_turn` / `user_turn` 是提交前的 Cue 保护拒绝；`failed: …` 仍可能已执行，不承诺未接受。
    case rejected(String)
    /// Pi 扩展回 `unknown_model`，其余几家的接入自己判断
    case unknownModel(AgentKind)
    /// Agent 明确没做这件事（托管的 Claude Code 没登录、模型不可用、额度用完时取消了这条命令或这句话）：原因是它自己的原话；确定没送达，可以重发
    case refused(String)
    /// 当前扩展尚未就绪；不能据此推断调用方的复合操作此前没有副作用。
    case upgradingExtension
    /// 已进入接入的复合操作，不能再把其中的升级错误用作准备证明。
    case operationStarted(ShownText)
    case unsupported
    /// 请求结束后未能确认真正退出；不据断线或重载推断结束成功。
    case notEnded
}

extension BridgeError: ShownError {
    private static let failedPrefix = "failed: "

    public var shown: String.LocalizationValue {
        switch self {
        case .insecureSocketDirectory(let path): "Agent 连接目录 \(path) 不安全：必须属于当前用户且权限为 0700"
        case .socketDirectoryTooLong: "Agent 连接目录的路径太长"
        case .unknownSession: "这个 Agent 会话已经结束"
        case .upgradingExtension: DeliveryPreparation.upgrading.value
        case .operationStarted(let reason): "会话操作已经开始，结果尚未确认：\(reason.embedded)"
        case .unsupported: "这个 Agent 会话不支持这样操作"
        case .notEnded: "尚未确认会话已结束"
        case .sessionEnded: "与 Agent 的连接已断开，操作结果尚未确认"
        case .ackTimeout: "尚未收到 Agent 的确认；操作可能已经执行，不会自动重试"
        case .rejected("unsupported_stop_turn"): "这个接入不支持按原回合停止，没有停止会话"
        case .rejected("upgrade_stop_turn"): "会话扩展需升级后才能按原回合停止，没有停止会话"
        case .rejected("stale_turn"): "原回合已结束或更换，停止请求不再适用，没有停止后来的工作"
        case .rejected("user_turn"): "会话已进入另一轮，Cue 没有打断"
        case .rejected("unconfirmed_turn"): "当前轮次的来源尚未确认，Cue 没有打断"
        case .rejected("no_prompt"), .rejected("stale_prompt"): "这个问题已经答过了，或 Agent 已经不在等这个问题"
        case .rejected("not_ready"): "终端里的会话还没起好，没有发出，可以重发"
        case .rejected("bad_answer"): "答案和问题对不上（选项不在列表里，或类型不对）"
        case .unknownModel(let agent): "\(agent.name) 里没有这个模型"
        case .refused(let reason): ShownText.verbatim(reason).value
        case .rejected("no_auth"): "这个模型的提供方在这台 Mac 上还没有登录或配置密钥"
        case .rejected("unknown_command"): "这个 Agent 会话里没有这个命令（可能已经被移除，或是只能在终端里用）"
        case .rejected("missing_argument"): "这个命令需要带上参数"
        case .rejected("nothing_to_retry"): "这个会话现在没有出错的一轮可重跑（它在跑，或最后一轮不是出错结束的）"
        // 扩展执行时出错（`failed: <原因>`）：原因就是要说的话
        case .rejected(let reason) where reason.hasPrefix(Self.failedPrefix): ShownText.verbatim(String(reason.dropFirst(Self.failedPrefix.count))).value
        case .rejected(let reason): "Agent 没有接受：\(reason)"
        }
    }
}
#endif

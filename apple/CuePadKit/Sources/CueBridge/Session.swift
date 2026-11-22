#if os(macOS)
import CueStore
import Foundation

public struct Session: Identifiable, Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let agent: AgentKind
    /// 首条消息落盘前该文件还不存在；`--no-session` 时为 nil，OpenCode 的会话在它的数据库里，也为 nil。
    public let sessionFile: URL?
    public let pid: Int32
    public let cwd: URL
    public internal(set) var state: WorkState
    public internal(set) var upgrading = false
    public internal(set) var detail: String? = nil
    public internal(set) var errorMessage: String? = nil
    public var failure: FailureKind? { state == .error ? ErrorSummary(errorMessage ?? "").failure : nil }
    public internal(set) var stateSince: Date
    public internal(set) var busySince: Date? = nil
    public internal(set) var turnStartedAt: Date? = nil
    public internal(set) var turnOpener: TurnOpener? = nil
    public internal(set) var name: String? = nil
    public internal(set) var firstMessage: String? = nil {
        didSet { if let firstMessage, firstMessage.count > SessionName.firstMessageLimit { self.firstMessage = SessionName.clipped(firstMessage) } }
    }
    public internal(set) var question: Question? = nil
    public internal(set) var launchToken: String? = nil
    public internal(set) var subagents: [SubagentState] = []
    public var confirmsFromHistory: Bool { agent.confirmsFromHistory }
    public internal(set) var model: ModelOption? = nil
    public internal(set) var thinking: Open<ThinkingLevel>? = nil
    public internal(set) var fast: Bool? = nil
    public internal(set) var availableModels: [ModelOption] = []
    public internal(set) var proofs: [PiProof] = []
    public internal(set) var context: ContextUsage? = nil
    public internal(set) var commands: [SlashCommand] = []

    public var modelState: ModelState { ModelState(model: model, thinking: thinking, fast: fast, models: availableModels) }

    public var capabilities: AgentCapabilities { .of(agent, model: model) }

    var carried: (state: WorkState, times: SessionTimes) { (state, SessionTimes(stateSince: stateSince, busySince: busySince)) }

    /// 第一条消息之前不建会话文件；不用会话文件的（OpenCode）一建就算。
    public var spoke: Bool {
        agent.facts.sessionFiles == nil || sessionFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    public func snapshot(title: String, projectID: UUID?) -> SessionSnapshot {
        var snapshot = SessionSnapshot(sessionID: sessionID, state: state, times: SessionTimes(stateSince: stateSince, busySince: busySince))
        snapshot.detail = detail
        snapshot.failure = failure
        snapshot.title = title
        snapshot.directory = cwd.path(percentEncoded: false)
        snapshot.projectID = projectID
        snapshot.question = question
        snapshot.turnStartedAt = turnStartedAt
        snapshot.turnOpener = turnOpener
        snapshot.launchToken = launchToken
        snapshot.hosted = true
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

extension Session {
    static func bridgeID(sessionID: String, pid: Int32) -> ID { "\(sessionID).\(pid)" }
}

public enum SessionName {
    public static let firstMessageLimit = 200

    static func clipped(_ text: String) -> String { String(text.prefix(firstMessageLimit)) }

    public static func display(name: String?, firstMessage: String?, folder: String) -> String {
        [name, firstMessage.map { SkillCall.shown(withoutImageNotes($0)) }].lazy
            .compactMap { $0.map { singleLine(AttachmentFiles.namingAgentLines(in: $0)) } }.first { !$0.isEmpty } ?? folder
    }

    public static func firstMessage(_ text: String) -> String? {
        let trimmed = SkillCall.shown(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : clipped(trimmed)
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
    case disconnected
    case closed(reason: String)

    public static let reload = SessionEndReason.closed(reason: "reload")
}

public enum SessionChange: Sendable, Equatable {
    case appeared(Session)
    case stateChanged(Session, from: WorkState)
    case infoChanged(Session)
    case ended(Session, reason: SessionEndReason)
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

public enum SendPolicy: Sendable, Equatable {
    case user
    case cue
}

public struct SessionMessage: Sendable, Equatable {
    public var text: String
    public var images: [MessageImage]
    public var deliveryID: String?
    public var policy: SendPolicy
    public init(text: String, images: [MessageImage] = [], deliveryID: String? = nil, policy: SendPolicy = .user) {
        self.text = text
        self.images = images
        self.deliveryID = deliveryID
        self.policy = policy
    }

    var opener: TurnOpener? { deliveryID.flatMap(UUID.init(uuidString:)).map { TurnOpener(delivery: $0, cue: policy == .cue) } }
}

public enum BridgeError: Error, Equatable {
    case insecureSocketDirectory(String)
    case socketDirectoryTooLong
    case unknownSession(String)
    case sessionEnded
    case ackTimeout
    case rejected(String)
    case unknownModel(AgentKind)
    case refused(String)
    case upgradingExtension
    case operationStarted(ShownText)
    case unsupported
    case notEnded
}

enum RejectReason: String {
    case empty
    case unknownCommand = "unknown_command", missingArgument = "missing_argument"
    case noPrompt = "no_prompt", stalePrompt = "stale_prompt", badAnswer = "bad_answer"
    case noAuth = "no_auth"
    case nothingToRetry = "nothing_to_retry"
    case unconfirmedTurn = "unconfirmed_turn", userTurn = "user_turn"
    case previousTurnRunning = "previous_turn_running"

    var shown: String.LocalizationValue? {
        switch self {
        case .empty: nil
        case .userTurn: "会话已进入另一轮，Cue 没有打断"
        case .unconfirmedTurn: "当前轮次的来源尚未确认，Cue 没有打断"
        case .previousTurnRunning: "正在做的那一轮没能停下，这句没有发出"
        case .noPrompt, .stalePrompt: "这个问题已经答过了，或 Agent 已经不在等这个问题"
        case .badAnswer: "答案和问题对不上（选项不在列表里，或类型不对）"
        case .noAuth: "这个模型的提供方在这台 Mac 上还没有登录或配置密钥"
        case .unknownCommand: "这个 Agent 会话里没有这个命令（可能已经被移除，或是只能在终端里用）"
        case .missingArgument: "这个命令需要带上参数"
        case .nothingToRetry: "这个会话现在没有出错的一轮可重跑（它正在工作，或最后一轮不是出错结束的）"
        }
    }
}

extension BridgeError {
    public var definitelyNotHanded: Bool {
        switch self {
        case .unknownSession, .unsupported, .unknownModel, .refused: true
        case .rejected(let reason): RejectReason(rawValue: reason) != nil
        default: false
        }
    }
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
        case .unknownModel(let agent): "\(agent.name) 里没有这个模型"
        case .refused(let reason): ShownText.verbatim(reason).value
        case .rejected(let reason):
            if let shown = RejectReason(rawValue: reason)?.shown { shown }
            else if reason.hasPrefix(Self.failedPrefix) { ShownText.verbatim(String(reason.dropFirst(Self.failedPrefix.count))).value }
            else { "Agent 没有接受：\(reason)" }
        }
    }
}
#endif

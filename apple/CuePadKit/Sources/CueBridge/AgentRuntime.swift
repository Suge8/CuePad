#if os(macOS)
import CueStore
import Foundation

/// 目录的唯一权威来源（Pi 与桥的在 `pi`）：环境变量与各家自己认的一致（隔离测试靠它们指到临时目录）。
public struct AgentPaths: Sendable, Equatable {
    public var pi: PiPaths
    public var environment: [String: String]

    public init(pi: PiPaths = PiPaths(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.pi = pi
        self.environment = environment
    }

    public func home(of kind: AgentKind) -> URL {
        let facts = kind.facts
        return facts.home?(self) ?? directory(facts.homeVariable) ?? user(facts.projectFolder)
    }

    /// 环境变量是 CuePad 自己的（各家都按家目录读它）：隔离实例与测试经它换到临时目录。
    public var agentsDirectory: URL { directory("CUEPAD_AGENTS_DIR") ?? user(".agents") }

    /// 全局规则的共享文件所在（`AgentLibraryPlaces.globalInstructions`）。环境变量同上，是 CuePad 自己的。
    public var agentsConfigDirectory: URL { directory("CUEPAD_AGENTS_CONFIG_DIR") ?? xdg("XDG_CONFIG_HOME", ".config").appending(path: "agents", directoryHint: .isDirectory) }

    public var userHome: URL { directory("HOME") ?? UserHome.directory }

    public func sessionsDirectory(of kind: AgentKind) -> URL? { kind.facts.sessionFiles?.directory(self) }

    public var openCodeService: URL {
        xdg("XDG_STATE_HOME", ".local/state").appending(path: "opencode/service.json")
    }

    func launchEnvironment(of kind: AgentKind) -> [String: String] {
        environment.merging([kind.facts.homeVariable: home(of: kind).path]) { $1 }
    }

    func directory(_ variable: String) -> URL? {
        environment[variable].flatMap { $0.isEmpty ? nil : URL(filePath: UserHome.expanding($0), directoryHint: .isDirectory) }
    }

    func xdg(_ variable: String, _ fallback: String) -> URL { directory(variable) ?? user(fallback) }

    /// `~`、`~/…` 按这里的家目录（环境给的 HOME）展开，别的原样。
    func expanding(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? userHome.path + path.dropFirst() : path
    }

    func user(_ path: String) -> URL { userHome.appending(path: path, directoryHint: .isDirectory) }
}

extension AgentKind {
    /// 唯一按家分派的一处，每家的写在它接入类型的 `+Facts` 文件里。
    public var facts: AgentFacts {
        switch self {
        case .pi: PiRuntime.facts
        case .claudeCode: ClaudeCodeRuntime.facts
        case .codex: CodexRuntime.facts
        case .opencode: OpenCodeRuntime.facts
        case .grok: GrokRuntime.facts
        case .dsh: DshRuntime.facts
        }
    }
}

/// 跨平台的名字、会话变量、模型提供方、能力在 CueStore 的 `AgentKind`。没写的项取多数家的值。
public struct AgentFacts: Sendable {
    public let command: String
    /// OpenCode 另认 `XDG_CONFIG_HOME`；不碰真实世界时没给它就不接入这家（`AgentInstallError.isolated`）。
    public let homeVariable: String
    var home: (@Sendable (AgentPaths) -> URL)?
    public var minimumVersion: AgentVersion?
    let installScript: String
    var upgradeCommand: String?
    public var installPrerequisite: InstallPrerequisite?
    /// 命令行登录的参数：打开浏览器，在网页上登录完它自己退出（不要终端）；没有的只能在它的终端界面里登录。
    public var loginArguments: [String]?
    var homeMeansInstalled = true
    var sessionFiles: SessionFileFormat?
    /// 托管的会话是 CuePad 为它起的进程：歇满 `Bridge.hostedIdle` 由桥请它退出（`Bridge.reviewHosted`）；
    /// 不是的自己计时或住在它的服务里。
    var releasesIdleHosted = false
    /// nil 是没登录，没回答抛错。
    let probe: @Sendable (_ executable: URL, AgentProbe) async throws -> MacAgent?
    let brain: @MainActor @Sendable () -> any HostedSession
    var sharedSkills = SharedSkills.recursive
    var skillFolders = ["skills"]
    let projectFolder: String
    var selfManagedSkills: String?
    /// 全局规则：CuePad 链到共享那份的位置（相对配置目录），与它原生读的几份（`globalReads`，按先后；`readsFirstOnly` 时只读第一份在的）。
    var instructionsFile = "AGENTS.md"
    var globalReads = ["AGENTS.md"]
    var readsFirstOnly = true
}

/// 读不到的技能 CuePad 逐个链到它自己的技能目录（`<配置目录>/skills/<名>`、项目里的 `<projectFolder>/skills/<名>`），整个目录链不行：
/// Claude Code 往自己的 `skills/synced` 写 claude.ai 同步的技能。
enum SharedSkills: Sendable {
    case recursive
    case topLevel
    case none

    func reaches(group: String) -> Bool { self == .recursive || self == .topLevel && group.isEmpty }
}

/// 投送执行器开会话、接着会话只经这里（按会话的 Agent 找到它）；对在线会话的一切（含结束）经桥。
@MainActor
public protocol AgentRuntime: AnyObject {
    func start() throws
    /// 返回的等待在它们都结束后结束，不需要主线程（App 退出时限时等）。
    func stop() -> @concurrent @Sendable () async -> Void
    /// 托管的会话撑得过 App 重启（退出、更新）：`stop()` 不收掉它们，新起的 App 经桥认回。更新只等撑不过的做完（`UpdateService`）。
    /// 缺省撑不过：托管的进程靠管道连着 App，`stop()` 收掉它们。
    var hostedSessionsOutliveApp: Bool { get }
    /// 等它上了桥，返回桥上的 id。会话名、模型、思考强度在开场的话之前一起生效（第一句话不会先当了会话名）：Pi 作为启动参数，其余上桥后一次配好（`configure(opened:…)`）。
    func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID
    func resume(_ session: IndexedSession) async throws -> Session.ID
    func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript
    func integrationRemoved() async
}

extension AgentRuntime {
    public var hostedSessionsOutliveApp: Bool { false }

    /// 配不上就结束它再抛：开工整体失败，不留会话。
    func configure(
        opened id: Session.ID, name: String?, model: ModelKey?, thinking: ThinkingLevel?, on bridge: Bridge
    ) async throws -> Session.ID {
        let name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard name != nil || model != nil || thinking != nil else { return id }
        do {
            try await bridge.configure(SessionConfig(model: model, thinking: thinking, name: name), in: id)
        } catch {
            try? await bridge.end(id)
            throw error
        }
        return id
    }

    public func integrationRemoved() async {}

    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript {
        try History.index(file: URL(filePath: session.path), agent: session.agent, from: nil, files: files).transcript
    }
}

public enum AgentRuntimeError: Error, Equatable {
    case notInstalled(AgentKind)
    case launchTimedOut(AgentKind)
    case launchFailed(AgentKind, String)
    /// 这个会话此刻开在别处（如终端里），后台不能再开一份（两边会各写各的）
    case openElsewhere
}

extension AgentRuntimeError: ShownError {
    public var shown: String.LocalizationValue {
        switch self {
        case .notInstalled(let kind): "这台 Mac 上没有找到 \(kind.name)"
        case .launchTimedOut(let kind): "\(kind.name) 没有及时启动"
        case .launchFailed(let kind, let reason): "\(kind.name) 没能启动：\(reason)"
        case .openElsewhere: "这个会话正开在别处（如终端里），先在那里退出再从 CuePad 接着说"
        }
    }
}
#endif

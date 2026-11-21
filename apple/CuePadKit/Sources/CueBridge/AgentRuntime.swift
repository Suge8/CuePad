#if os(macOS)
import CueStore
import Foundation

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

    public var agentsDirectory: URL { directory("CUEPAD_AGENTS_DIR") ?? user(".agents") }

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

    func expanding(_ path: String) -> String {
        path == "~" || path.hasPrefix("~/") ? userHome.path + path.dropFirst() : path
    }

    func user(_ path: String) -> URL { userHome.appending(path: path, directoryHint: .isDirectory) }
}

extension AgentKind {
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

public struct AgentFacts: Sendable {
    public let command: String
    /// OpenCode 另认 `XDG_CONFIG_HOME`；不碰真实世界时没给它就不读这家（`AgentFileAccess.touches`）。
    public let homeVariable: String
    var home: (@Sendable (AgentPaths) -> URL)?
    public var minimumVersion: AgentVersion?
    let installScript: String
    var installDirectory: String?
    var upgradeCommand: String?
    public var installPrerequisite: InstallPrerequisite?
    /// 命令行登录的参数：打开浏览器，在网页上登录完它自己退出（不要终端）；没有的只能在它的终端界面里登录。
    public var loginArguments: [String]?
    var homeMeansInstalled = true
    var sessionFiles: SessionFileFormat?
    var releasesIdleHosted = false
    let probe: @Sendable (_ executable: URL, AgentProbe) async throws -> MacAgent?
    let brain: @MainActor @Sendable () -> any HostedSession
    var sharedSkills = SharedSkills.recursive
    var skillFolders = ["skills"]
    let projectFolder: String
    var selfManagedSkills: String?
    var instructionsFile = "AGENTS.md"
    var globalReads = ["AGENTS.md"]
    var readsFirstOnly = true
    var compactsAt: (@Sendable (_ window: Int, ModelKey?, AgentPaths) -> Int?)?
}

/// 读不到的技能 CuePad 逐个链到它自己的技能目录（`<配置目录>/skills/<名>`、项目里的 `<projectFolder>/skills/<名>`），整个目录链不行：
/// Claude Code 往自己的 `skills/synced` 写 claude.ai 同步的技能。
enum SharedSkills: Sendable {
    case recursive
    case topLevel
    case none

    func reaches(group: String) -> Bool { self == .recursive || self == .topLevel && group.isEmpty }
}

@MainActor
public protocol AgentRuntime: AnyObject {
    func start() throws
    func stop() -> @concurrent @Sendable () async -> Void
    var hostedSessionsOutliveApp: Bool { get }
    func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID
    func resume(_ session: IndexedSession) async throws -> Session.ID
    func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript
    func stepDetail(_ calls: [String], of session: IndexedSession) async throws -> ToolCallDetail
}

extension AgentRuntime {
    public var hostedSessionsOutliveApp: Bool { false }

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

    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript {
        try History.index(file: URL(filePath: session.path), agent: session.agent, from: nil, files: files).transcript
    }

    public func stepDetail(_ calls: [String], of session: IndexedSession) async throws -> ToolCallDetail {
        try await ToolCallDetail.read(file: URL(filePath: session.path), calls: calls)
    }
}

public enum AgentRuntimeError: Error, Equatable {
    case notInstalled(AgentKind)
    case launchTimedOut(AgentKind)
    case launchFailed(AgentKind, String)
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

#if os(macOS)
import CueAgent
import CueStore
import Foundation

public struct CueBrainConfig: Sendable {
    public let runtime: AgentKind
    public let executable: URL
    public let model: String?
    public let effort: ThinkingLevel?
    public let fast: Bool
    public let systemPrompt: String
    public let workingDirectory: URL
    public let mcp: [String]
    public let environment: [String: String]
    public let timing: Timing

    public init(
        runtime: AgentKind, executable: URL, model: String?, effort: ThinkingLevel?, fast: Bool = false, systemPrompt: String,
        workingDirectory: URL, mcp: [String], environment: [String: String], timing: Timing = .system
    ) {
        self.runtime = runtime
        self.executable = executable
        self.model = model
        self.effort = effort
        self.fast = fast
        self.systemPrompt = systemPrompt
        self.workingDirectory = workingDirectory
        self.mcp = mcp
        self.environment = environment
        self.timing = timing
    }
}

/// 一轮进行中再 `send` 的话多半并进这一轮，赶上这一轮收尾就另起一轮：哪一轮接走了它只看 `received`。
/// 子代理与嵌套的工具调用、子代理说的话不报。
/// Cue 的工具服务在班次中途没了：之后调它的工具时各家在工具结果里报的（实测 Pi 1.5.0、Codex 0.167.0、OpenCode 2.2.6、Claude Code 2.1.318）。
/// Pi 是随包的 cue-tools.ts 带上 `marker` 的那两句（标记经环境变量交给它，只此一份）；Codex 报这个 MCP 服务的传输断了；
/// OpenCode 把这个服务的工具整个撤掉，报没有这个工具；Claude Code 自己重起服务、照常调到，不会走到这里。
public enum CueToolsDown {
    public static let marker = "[cuepad-tools-down]"

    public static func matches(_ result: String) -> Bool {
        result.hasPrefix(marker)
            || result.contains("tool call failed for `\(CueMCPServer.name)/") && result.contains("Transport closed")
            || result.hasPrefix("No tool named \"\(CueMCPServer.toolPrefix(on: .opencode))")
    }
}

public enum TurnEvent: Sendable, Equatable {
    case turnStarted
    case received(UUID)
    case speaking(LiveDraft?)
    case context(used: Int, window: Int?)
    case tool(id: String, name: String, arguments: String)
    case toolDone(id: String, result: String, failed: Bool)
    case turnFinished
    case failed(String)
    case exited(ShownText?)
}

@MainActor
public protocol HostedSession: AnyObject {
    var events: AsyncStream<TurnEvent> { get }
    func start(_ config: CueBrainConfig) async throws
    var seesImages: Bool { get }
    func send(_ text: String, images: [MessageImage], id: UUID) async throws
    func newSession() async throws
    func configure(model: String?, effort: ThinkingLevel?) async throws
    func stop() -> @concurrent @Sendable () async -> Void
}

public enum HostedSessionError: Error, Equatable {
    case notRunning
    case rejected(String)
}

extension HostedSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning: String(localized: "Cue 没在运行")
        case .rejected(let message): String(localized: "Cue 的运行时拒绝了请求：\(message)")
        }
    }
}

extension CueBrainConfig {
    func launchEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        ExecutableLocator(searchDirectories: []).environment(launching: executable, overrides: environment.merging(extra) { $1 })
    }

    @MainActor public func startBrain() async throws -> any HostedSession {
        let brain = runtime.facts.brain()
        try await brain.start(self)
        return brain
    }
}
#endif

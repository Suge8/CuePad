#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 当 Cue 的大脑开（`init(dialect:)` 再 `start`）：不挂桥、不进会话列表，一轮的状态与托管会话同一套，经 `events` 交出。
/// 系统提示、工具白名单与不落会话这些标准没有的配法在各家（`ACPDialect.brain`）；CuePad 的 MCP 服务照标准随 `session/new` 交（stdio）。
/// - 会话开好、CuePad 的 MCP 服务连上之后才算起好（`ACPDialect.connectsMCPLater` 的那几家等它报），之前说的话模型用不了它的工具；
/// - 正忙时说的话经各家并进这一轮（`ACPDialect.steer`），做不到的等这一轮做完再开新的一轮；他的话以 `/` 开头时前面垫一个空格，
///   不被当成斜杠命令；
/// - 开新会话是另开一个 `session/new`（进程与 MCP 服务的配置不变），就地换过的模型与强度随后再交一次。
extension ACPSession: HostedSession {
    var events: AsyncStream<TurnEvent> { brain?.events ?? AsyncStream { $0.finish() } }

    func start(_ config: CueBrainConfig) async throws {
        guard let brain else { throw HostedSessionError.notRunning }
        do {
            let setup = try dialect.brain(config, directory: try brain.makeDirectory())
            try await launch(config.executable, environment: config.launchEnvironment(adding: setup.environment), directory: config.workingDirectory)
            brainSetup = (config, setup)
            try await openBrain()
            try await configure(model: config.model, effort: config.effort)
        } catch {
            await brain.abandon(stop())
            throw error
        }
    }

    /// 开大脑的会话，等 CuePad 的 MCP 服务连上。
    private func openBrain() async throws {
        guard let (config, setup) = brainSetup else { throw HostedSessionError.notRunning }
        let server: JSONValue = [
            "name": .string(CueMCPServer.name), "command": .string(config.mcp[0]), "args": .array(config.mcp.dropFirst().map(JSONValue.string)),
            "env": .array(config.environment.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": .string($0.value)] }),
        ]
        try await open(in: config.workingDirectory, mcpServers: [server], meta: setup.meta)
        try await mcpReady(within: AgentTimeouts.launch)
    }

    func send(_ text: String, images: [PiImage]) async throws {
        let text = text.hasPrefix("/") ? " " + text : text
        if facts.running {
            guard let sessionID else { throw HostedSessionError.notRunning }
            if try await dialect.steer(text, images: images, session: sessionID, on: live) { return }
            await untilFinished()
        }
        try prompt(ACPContent.prompt(text: text, images: images))
    }

    func newSession() async throws {
        try await openBrain()
        let (model, effort) = configured
        if model != nil || effort != nil { try await configure(model: model, effort: effort) }
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = connection?.process
        return { await process?.stop() }
    }
}
#endif

#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 当 Cue 的大脑开（`init(dialect:)` 再 `start`）：不挂桥、不进会话列表，一轮的状态与托管会话同一套，经 `events` 交出。
/// 系统提示、工具白名单与不落会话这些标准没有的配法在各家（`ACPDialect.brain`）；CuePad 的 MCP 服务照标准随 `session/new` 交（stdio）。
/// - 会话开好、CuePad 的 MCP 服务连上之后才算起好（`ACPDialect.connectsMCPLater` 的那几家等它报），之前说的话模型用不了它的工具；
/// - 正忙时说的话经各家并进这一轮（`ACPDialect.steer`，只并进 CuePad 开的那一轮），做不到的等这一轮做完再开新的一轮；他的话以 `/` 开头时前面垫一个空格，
///   不被当成斜杠命令。哪一轮收下：以它开的那一轮（`session/prompt` 就是这一轮）；并进的按各家报的（`ACPSteers`）；
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

    /// 插不进这一轮的等它做完再开一轮。
    func send(_ text: String, images: [PiImage], id: UUID) async throws {
        let text = text.hasPrefix("/") ? " " + text : text
        if facts.running {
            guard let sessionID else { throw HostedSessionError.notRunning }
            if steerable, let steer = try await dialect.steer(text, images: images, session: sessionID, on: live) {
                if let taken = steers.add(id, text: text, claim: steer.claim) { emit(.received(taken)) }
                return
            }
            await untilFinished()
        }
        try prompt(ACPContent.prompt(text: text, images: images))
        emit(.received(id))
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

/// 大脑插进在跑这一轮、还没认出哪一轮收下的话（`ACPSteer`）：各家报收下的（`claim`）就此认；搁浅的（`ACPSignal.stranded`，按原话认）
/// 是 Agent 接着自己开的那一轮收下的；其余的到插进的那一轮结束时就是它收下的（`ended`）。
struct ACPSteers {
    private var waiting: [(id: UUID, text: String, claim: String?)] = []
    /// 先于插话的回应报来的收下
    private var claimedEarly: Set<String> = []
    private var stranded: [UUID] = []

    /// 插进了一句；它的收下已先报来就返回它。
    mutating func add(_ id: UUID, text: String, claim: String?) -> UUID? {
        if let claim, claimedEarly.remove(claim) != nil { return id }
        waiting.append((id, text, claim))
        return nil
    }

    /// 报来收下（`ACPSignal.claimed`）：是插进的哪一句；它的回应还没到为 nil。
    mutating func claimed(_ claim: String) -> UUID? {
        guard let index = waiting.firstIndex(where: { $0.claim == claim }) else {
            claimedEarly.insert(claim)
            return nil
        }
        return waiting.remove(at: index).id
    }

    /// Agent 以这些原话自己开了一轮：不报收下的那几句里在其中的，归那一轮。
    mutating func strand(_ text: String) {
        stranded += waiting.filter { $0.claim == nil && text.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }.map(\.id)
        waiting.removeAll { stranded.contains($0.id) }
    }

    /// 插进的那一轮结束：还等着的是它收下的。
    mutating func ended() -> [UUID] {
        defer { waiting = [] }
        return waiting.map(\.id)
    }

    mutating func takeStranded() -> [UUID] {
        defer { stranded = [] }
        return stranded
    }
}
#endif

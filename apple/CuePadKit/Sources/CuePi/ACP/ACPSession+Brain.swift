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

    /// 插不进这一轮的等它做完再开一轮：一轮结束时 Agent 可能当场接着自己开一轮（Grok 的搁浅插话），醒来再看一次。
    func send(_ text: String, images: [PiImage], id: UUID) async throws {
        let text = text.hasPrefix("/") ? " " + text : text
        while facts.running {
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
        steers = ACPSteers()
        try await openBrain()
        let (model, effort) = configured
        if model != nil || effort != nil { try await configure(model: model, effort: effort) }
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = connection?.process
        return { await process?.stop() }
    }
}

/// 大脑插进在跑这一轮、还没认出哪一轮收下的话（`ACPSteer`）：各家报收下的（`claim`）只按那个报告认，这一轮结束也不算；
/// 不报的里搁浅的（`ACPSignal.stranded`）是 Agent 接着自己开的那一轮收下的——一轮一句，按原话整句认；其余的到插进的那一轮结束时就是它收下的（`ended`）。
/// Grok 1.0.70 实测：这一轮不再请求模型之后插进的都搁浅，按插进的先后每句各开一轮（`runningText` 就是那一句），
/// 第 n+1 句的那一轮要等第 n 句那一轮做完才报。所以头一回报搁浅的那句之后插进的也都已搁浅，先挪出来等各自那一轮，不归插进的那一轮。
struct ACPSteers {
    private typealias Steer = (id: UUID, text: String, claim: String?)
    private var waiting: [Steer] = []
    /// 先于插话的回应报来的收下
    private var claimedEarly: Set<String> = []
    /// 已搁浅、它那一轮还没报的（按插进的先后）
    private var strandedLater: [Steer] = []
    /// 报了搁浅、下一个 Agent 自己开的一轮收下的
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

    /// Agent 以这句原话自己开了一轮：原话就是它的、最早插进的那一句归那一轮；先在已搁浅的里找，再在还等着的里找——
    /// 后一种是这一轮头一回报搁浅，那句之后插进、不报收下的一并挪进已搁浅。都对不上不认（不猜是哪一句）。
    mutating func strand(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let same = { (steer: Steer) in steer.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }
        if let index = strandedLater.firstIndex(where: same) { return stranded.append(strandedLater.remove(at: index).id) }
        guard let index = waiting.firstIndex(where: { $0.claim == nil && same($0) }) else { return }
        stranded.append(waiting[index].id)
        let later = waiting[(index + 1)...].filter { $0.claim == nil }
        strandedLater += later
        waiting.remove(at: index)
        waiting.removeAll { steer in later.contains { $0.id == steer.id } }
    }

    /// 插进的那一轮结束：还等着、这家不报收下的是它收下的；报收下的还没报的留着等报告。
    mutating func ended() -> [UUID] {
        defer { waiting.removeAll { $0.claim == nil } }
        return waiting.filter { $0.claim == nil }.map(\.id)
    }

    mutating func takeStranded() -> [UUID] {
        defer { stranded = [] }
        return stranded
    }
}
#endif

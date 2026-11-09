#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 各家与标准不同的地方只经 `ACPDialect`。一轮的状态在这里判一次，同一处交给两边——事件（`emit`，大脑的事件流）与桥上的事实（`facts`、草稿、上下文）。
/// 各家报 CuePad 开的那一轮结束时只记下出错的原文，等回应再结束：回应之前各家还会报这一轮之后的事（Grok 把搁浅的插话转成它自己开的一轮，
/// 1.0.70 实测先于回应到），要排在这一轮结束之后。回应只结束它自己开的那一轮；被停下（`session/cancel`）照常结束、不算出错；回错误的是出错（各家报的原文，没有就是 `ACPError` 的原话）。
/// 正在说的话：`agent_message_chunk` 逐字累积（ACP 不分条：工具调用前后各是一条）。
/// 载入旧会话（`session/load`）时 Agent 把历史重放成通知：不算。
@MainActor
final class ACPSession {
    let dialect: any ACPDialect
    private(set) weak var bridge: PiBridge?
    private(set) weak var processes: HostedProcesses?
    let brain: BrainSession?
    private(set) var connection: ACPConnection?
    private(set) var sessionID: String?
    private(set) var cwd: URL?
    private(set) var id: PiSession.ID?
    var facts = SessionFacts()
    private(set) var opened: JSONValue = [:]
    var options: [JSONValue] = []
    var pending: (request: JSONValue, ask: ACPAsk)?
    /// 一轮一个编号：`session/prompt` 的回应只结束它自己开的那一轮
    private var turn = 0
    /// 在跑的是 CuePad 的 `session/prompt` 开的那一轮（它的编号）；Agent 自己开的为 nil
    private var prompted: Int?
    /// 先排进队列的家（`ACPDialect.queuesPrompts`）已报它跑起来了
    private var promptRunning = false
    /// 各家报的这一轮出错的原文，等回应结束这一轮时用
    private var reported: String?
    /// 回应之前各家已报它自己接着开了一轮（`ACPSignal.stranded`）：这一轮结束后接着开
    private var agentTurnNext = false
    var steers = ACPSteers()
    private var draft: DraftParts?
    /// 停下这一轮后它的结束不算出错
    private var stopping = false
    /// 等这一轮变化的（排着的那一句跑起来、这一轮结束）；进程退出时也放行。大脑等一轮自然做完，不限时
    private let changes = PendingReplies<UUID, Void>(timeout: nil, timeoutError: PiBridgeError.ackTimeout)
    /// 停下这一轮后等它结束的：取消的回应不来（Agent 收下取消却不回也不断线）时到 `AgentTimeouts.stop` 放弃
    private let stops: PendingReplies<UUID, Void>
    let stopPhase = StopPhase()
    private var loading = false
    /// CuePad 的 MCP 服务连上没有（`ACPDialect.connectsMCPLater`）：nil 是这个会话还没报
    private var mcp: Result<Void, HostedSessionError>?
    private var mcpWaiters: [CheckedContinuation<Void, Never>] = []
    private var contextUsed: Int?
    var contextWindow: Int?
    var brainSetup: (config: CueBrainConfig, setup: ACPBrainSetup)?
    var configured: (model: String?, effort: PiThinkingLevel?) = (nil, nil)

    init(dialect: any ACPDialect, bridge: PiBridge, processes: HostedProcesses, timing: Timing = .system) {
        self.dialect = dialect
        self.bridge = bridge
        self.processes = processes
        brain = nil
        stops = PendingReplies(timeout: AgentTimeouts.stop, timing: timing, timeoutError: PiBridgeError.ackTimeout)
    }

    init(dialect: any ACPDialect) {
        self.dialect = dialect
        brain = BrainSession()
        stops = PendingReplies(timeout: AgentTimeouts.stop, timeoutError: PiBridgeError.ackTimeout)
    }

    /// 起好的连接；没起或进程已退出时抛错（托管会话 `sessionEnded`，大脑 `notRunning`）
    var live: ACPConnection {
        get throws {
            guard let connection, !connection.isClosed else { throw brain == nil ? PiBridgeError.sessionEnded : HostedSessionError.notRunning }
            return connection
        }
    }

    var agent: AgentKind { dialect.agent }
    var seesImages: Bool { connection.map { dialect.acceptsImages($0.agent) } ?? false }

    func launch(
        _ executable: URL, environment: [String: String], directory: URL, timing: Timing = .system, spawned: (ChildProcess) async throws -> Void = { _ in }
    ) async throws {
        let connection = try await ACPConnection.launch(
            executable, dialect.arguments, environment: environment, directory: directory, timing: timing, spawned: spawned)
        connection.onNotification = { [weak self] in self?.notified($0, $1) }
        connection.onRequest = { [weak self] method, params, request in self?.asked(method, params, request: request) ?? false }
        connection.onClose = { [weak self] in self?.ended() }
        self.connection = connection
    }

    func open(in directory: URL, mcpServers: [JSONValue] = [], meta: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["cwd": .string(directory.path), "mcpServers": .array(mcpServers)]
        if let meta { params["_meta"] = meta }
        mcp = nil
        let result = try await live.call("session/new", .object(params))
        guard let id = result["sessionId"]?.string else { throw ACPError.server(code: 0, message: "session/new 没有回会话 id") }
        adopt(id, in: directory, result)
    }

    func load(_ sessionID: String, in directory: URL) async throws {
        loading = true
        defer { loading = false }
        let result = try await live.call("session/load", ["sessionId": .string(sessionID), "cwd": .string(directory.path), "mcpServers": []])
        adopt(sessionID, in: directory, result)
    }

    private func adopt(_ sessionID: String, in directory: URL, _ result: JSONValue) {
        self.sessionID = sessionID
        cwd = directory
        opened = result
        options = result["configOptions"]?.array ?? []
        contextWindow = currentModel.flatMap { dialect.window(of: $0, in: opened) }
    }

    func attach(_ session: PiSession) {
        id = session.id
        var session = session
        publishOptions(to: &session)
        bridge?.attach(session, via: self)
    }

    func mcpReady(within limit: Duration) async throws {
        guard dialect.connectsMCPLater else { return }
        if mcp == nil {
            let timer = Task { [weak self] in
                guard (try? await Task.sleep(for: limit)) != nil, let self, self.mcp == nil else { return }
                self.settleMCP(.failure(.rejected(String(localized: "CuePad 的 MCP 服务没有及时连上"))))
            }
            await withCheckedContinuation { mcpWaiters.append($0) }
            timer.cancel()
        }
        try mcp?.get()
    }

    private func settleMCP(_ outcome: Result<Void, HostedSessionError>) {
        mcp = outcome
        mcpWaiters.forEach { $0.resume() }
        mcpWaiters = []
    }

    /// 读到回应的那一刻这一轮结束，之后读到的通知归下一轮。
    func prompt(_ blocks: [JSONValue], deliveryID: String? = nil) throws {
        let connection = try live
        guard let sessionID else { throw HostedSessionError.notRunning }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "prompt": .array(blocks)]
        if let meta = dialect.promptMeta(deliveryID: deliveryID) { params["_meta"] = meta }
        let mine = begin()
        prompted = mine
        promptRunning = !dialect.queuesPrompts
        connection.request("session/prompt", .object(params)) { [weak self] reply in
            switch reply {
            case .success: self?.finish(mine, failure: nil)
            case .failure(.server(_, let message)): self?.finish(mine, failure: message)
            case .failure: break  // 进程退出：由 `ended` 收尾
            }
        }
    }

    func interrupt(cancellable: Bool = true) async throws {
        try await stopPhase.run(cancellable: cancellable) { [self] in
            guard facts.running, let sessionID else { return }
            stopping = true
            decline()
            try live.notify("session/cancel", ["sessionId": .string(sessionID)])
            try await untilFinished()
        }
    }

    /// 在跑的是 CuePad 开的那一轮：插话只并进它（Agent 自己开的一轮各家不保证收下，等它做完再开）
    var steerable: Bool { facts.running && prompted == turn && promptRunning }

    /// 等这一轮结束（没在跑立即返回，进程退出时也返回）；取消的回应不来时到 `AgentTimeouts.stop` 抛 `ackTimeout`。
    func untilFinished() async throws {
        let current = turn
        while turn == current, facts.running, connection?.isClosed == false { try await stops.wait() }
    }

    /// 等这一轮变一次：排着的那一句跑起来、这一轮结束，或进程退出；没在跑或进程已退出时立即返回。不限时（大脑等一轮自然做完）。
    func nextChange() async throws {
        guard facts.running, connection?.isClosed == false else { return }
        try await changes.wait()
    }

    private func begin() -> Int {
        turn += 1
        facts.startTurn(at: .now)
        speak(nil)
        emit(.turnStarted)
        publish()
        return turn
    }

    /// 这一轮结束；`which` 是 `session/prompt` 开的那一轮的编号（别的轮的回应不算），nil 是各家报的结束（Agent 自己开的那一轮）。
    /// 插进来、还没认出被收下的话是这一轮收下的（`ACPSteers`）；回应之前各家报了它接着开的一轮，这就开。
    private func finish(_ which: Int?, failure: String?) {
        guard facts.running, which.map({ $0 == turn }) ?? true else { return }
        let stopped = stopping
        stopping = false
        let failure = stopped ? nil : reported ?? failure
        prompted = nil
        reported = nil
        if stopped || failure != nil { speak(nil) }
        decline()
        facts.endTurn(failure: failure)
        for id in steers.ended() { emit(.received(id)) }
        if let failure { emit(.failed(failure)) }
        emit(.turnFinished)
        release()
        publish()
        if agentTurnNext {
            agentTurnNext = false
            beginStranded()
        }
    }

    private func beginStranded() {
        _ = begin()
        for id in steers.takeStranded() { emit(.received(id)) }
    }

    private func release() {
        changes.releaseAll()
        stops.releaseAll()
    }

    private func decline() {
        guard let pending else { return }
        self.pending = nil
        facts.questions = []
        connection?.respond(to: pending.request, result: pending.ask.withdrawn)
    }

    func present(_ ask: ACPAsk, request: JSONValue) {
        var ask = ask
        ask.question.promptID = UUID().uuidString
        pending = (request, ask)
        facts.questions = [ask.question]
        publish()
    }

    func emit(_ event: TurnEvent) {
        brain?.emit(event)
        if let id { bridge?.show(event, in: id) }
    }

    func publish() {
        guard let id else { return }
        bridge?.update(id) { facts.publish(to: &$0) }
    }

    private func speak(_ next: DraftParts?) {
        guard next != nil || draft != nil else { return }
        draft = next
        emit(.speaking(next?.draft))
    }

    private func noteContext(used: Int, window: Int?) {
        guard used > 0, used != contextUsed || window != contextWindow else { return }
        contextUsed = used
        contextWindow = window
        emit(.context(used: used, window: window))
    }

    /// 这个会话的通知。MCP 服务连上的通知不论哪个会话都认：它可能先于 `session/new` 的回应到，进程里也只有这一个会话在开。
    private func notified(_ method: String, _ params: JSONValue) {
        guard !loading else { return }
        let mine = sessionID != nil && params["sessionId"]?.string == sessionID
        if mine, method == "session/update", let update = params["update"] { updated(update) }
        for signal in dialect.signals(method, params) {
            if case .mcp(let failure) = signal {
                settleMCP(failure.map { .failure(.rejected(String(localized: "CuePad 的 MCP 服务连不上：\($0)"))) } ?? .success(()))
            } else if mine {
                apply(signal)
            }
        }
        if mine { publish() }
    }

    private func apply(_ signal: ACPSignal) {
        switch signal {
        case .turnStarted:
            if !facts.running {
                _ = begin()
            } else if prompted == turn, !promptRunning {
                promptRunning = true
                release()
            }
        case .turnFinished(let failure):
            guard facts.running, prompted == turn else { return finish(nil, failure: failure) }
            // 它已不再收插话：之后的话等回应结束这一轮再开新的一轮
            reported = failure
            promptRunning = false
        case .context(let used): noteContext(used: used, window: contextWindow)
        case .claimed(let claim): if let id = steers.claimed(claim) { emit(.received(id)) }
        case .stranded(let text):
            steers.strand(text)
            if facts.running { agentTurnNext = true } else { beginStranded() }
        case .mcp: break
        }
    }

    private func updated(_ update: JSONValue) {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard facts.running, let text = update["content"]?["text"]?.string else { return }
            var parts = draft ?? DraftParts()
            parts.append(text, to: 0)
            speak(parts)
            facts.work(.thinking)
        case "agent_thought_chunk":
            if facts.running { facts.work(.thinking) }
        case "tool_call":
            guard facts.running else { return }
            speak(nil)
            let (name, input) = dialect.tool(update)
            facts.work(.tool, detail: ToolDetail.line(name, input))
            emit(.tool(id: update["toolCallId"]?.string ?? "", name: CueMCPServer.bareName(name, on: agent), arguments: String(decoding: input.data, as: UTF8.self)))
            toolSettled(update)
        case "tool_call_update":
            toolSettled(update)
        case "available_commands_update":
            let listed = (update["availableCommands"]?.array ?? []).compactMap { command -> PiSlashCommand? in
                guard let name = command["name"]?.string else { return nil }
                return PiSlashCommand(
                    name: name, summary: command["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.builtin),
                    hint: command["input"]?["hint"]?.string)
            }
            if let id { bridge?.update(id) { $0.commands = listed } }
        case "config_option_update":
            if let updated = update["configOptions"]?.array { adopt(options: updated) }
        case "session_info_update":
            if let title = update["title"]?.string, let id { bridge?.update(id) { $0.name = title } }
        case "usage_update":
            if let used = update["used"]?.int { noteContext(used: used, window: update["size"]?.int ?? contextWindow) }
        default:
            break
        }
    }

    private func toolSettled(_ update: JSONValue) {
        guard facts.running, let status = update["status"]?.string, status == "completed" || status == "failed" else { return }
        facts.work(.thinking)
        emit(.toolDone(id: update["toolCallId"]?.string ?? "", result: dialect.toolResult(update), failed: status == "failed"))
    }

    private func asked(_ method: String, _ params: JSONValue, request: JSONValue) -> Bool {
        guard params["sessionId"]?.string == sessionID else { return false }
        let isPermission = method == "session/request_permission"
        guard let ask = isPermission ? ACPAsk.permission(params, agent: agent, dialect: dialect) : dialect.ask(method, params) else { return false }
        guard brain == nil else {
            connection?.respond(to: request, result: isPermission ? ACPAsk.allowed(params) : ask.withdrawn)
            return true
        }
        decline()
        present(ask, request: request)
        return true
    }

    private func ended() {
        release()
        if mcp == nil { settleMCP(.failure(.notRunning)) }
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
        if let brain, let process = connection?.process {
            Task { brain.exited(await process.exited()) }
        }
    }
}
#endif

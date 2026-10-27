#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// CuePad 起的一个 ACP Agent 进程（`ACPConnection`）与它上面的一个会话：ACP 的驱动，这个会话的一轮只在这里判，同一处交给两边——
/// 事件（`emit`，大脑的事件流）与桥上的事实（`facts`、草稿、上下文）。两种开法：
/// - 托管会话（`init(dialect:bridge:)` → `launch` → `open` 或 `load` → `attach`）：上桥、进会话列表，控制见 +Control；
/// - Cue 的大脑（`init(dialect:)` → `start`，`HostedSession`，见 +Brain）。
/// 各家与标准不同的地方只经 `ACPDialect`。
///
/// - 一轮：CuePad 发出 `session/prompt` 起，到它的回应止（回应只结束它自己开的那一轮）；Agent 自己开、自己结束的一轮由各家报（`ACPSignal`）。
///   被停下（`session/cancel`）照常结束、不算出错；回错误的是出错（`ACPError` 的原话）。
/// - 正在说的话：`agent_message_chunk` 逐字累积（ACP 不分条：工具调用前后各是一条），开出工具调用、停下、出错、下一轮开始时清掉。
/// - 工具：`tool_call` 开始，`tool_call_update`（或 `tool_call` 本身）的 `completed`、`failed` 结束；名字与结果的文字经各家（`ACPDialect`）。
/// - 上下文：标准的 `usage_update`（`used`、`size`），或各家报的输入合计（`ACPSignal.context`，窗口取各家给的模型窗口）。
/// - 模型与强度：会话的配置项（`configOptions` 里 `category` 为 `model`、`thought_level` 的两项，`config_option_update` 随时换掉），
///   换用 `session/set_config_option`；强度的值照 `PiThinkingLevel` 的写法对上，夹到这一项有的档位。
/// - Agent 要你回答的（`ACPAsk`：标准的权限确认，各家的提问请求经 `ACPDialect.ask`）：托管会话成为 CuePad 里的提问（+Control），
///   一次只等一问，又来一问、停下或结束这一轮时没答的作废；大脑没人可问：权限一律允许（它只有读文件与 CuePad 的工具），提问作废。
/// - 载入旧会话（`session/load`）时 Agent 把历史重放成通知：不算。
@MainActor
final class ACPSession {
    let dialect: any ACPDialect
    /// 托管会话挂的桥；大脑没有
    private(set) weak var bridge: PiBridge?
    /// 大脑的事件流与临时目录；托管会话没有
    let brain: BrainSession?
    private(set) var connection: ACPConnection?
    /// Agent 给的会话 id
    private(set) var sessionID: String?
    /// 会话的工作目录
    private(set) var cwd: URL?
    /// 上了桥之后的 id
    private(set) var id: PiSession.ID?
    var facts = SessionFacts()
    /// 开会话的结果（各家的模型清单在里面，`ACPDialect.window`）
    private(set) var opened: JSONValue = [:]
    /// 会话的配置项（`configOptions`）
    private(set) var options: [JSONValue] = []
    /// 在等你回答的（Agent 的请求 id 与这一问）
    var pending: (request: JSONValue, ask: ACPAsk)?
    /// 一轮一个编号：`session/prompt` 的回应只结束它自己开的那一轮
    private var turn = 0
    private var draft: DraftParts?
    /// 停下这一轮后它的结束不算出错
    private var stopping = false
    /// 等这一轮结束的；进程退出时也放行
    private var closing: [CheckedContinuation<Void, Never>] = []
    private var loading = false
    /// CuePad 的 MCP 服务连上没有（`ACPDialect.connectsMCPLater`）：nil 是这个会话还没报
    private var mcp: Result<Void, HostedSessionError>?
    private var mcpWaiters: [CheckedContinuation<Void, Never>] = []
    private var contextUsed: Int?
    private var contextWindow: Int?
    /// 大脑的配置与各家的配法（开新会话时照它再开）
    var brainSetup: (config: CueBrainConfig, setup: ACPBrainSetup)?
    /// 就地换过的模型与强度
    var configured: (model: String?, effort: PiThinkingLevel?) = (nil, nil)

    /// 托管会话：`launch`、`open`/`load` 后 `attach` 上桥。
    init(dialect: any ACPDialect, bridge: PiBridge) {
        self.dialect = dialect
        self.bridge = bridge
        brain = nil
    }

    /// Cue 的大脑：`start` 起进程。
    init(dialect: any ACPDialect) {
        self.dialect = dialect
        brain = BrainSession()
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

    // MARK: 起与开

    /// 起 Agent 的 ACP 服务并握手，接上它的通知与请求。
    func launch(_ executable: URL, environment: [String: String], directory: URL) async throws {
        let connection = try await ACPConnection.launch(executable, dialect.arguments, environment: environment, directory: directory)
        connection.onNotification = { [weak self] in self?.notified($0, $1) }
        connection.onRequest = { [weak self] method, params, request in self?.asked(method, params, request: request) ?? false }
        connection.onClose = { [weak self] in self?.ended() }
        self.connection = connection
    }

    /// 开一个新会话（`session/new`）。
    func open(in directory: URL, mcpServers: [JSONValue] = [], meta: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["cwd": .string(directory.path), "mcpServers": .array(mcpServers)]
        if let meta { params["_meta"] = meta }
        mcp = nil
        let result = try await live.call("session/new", .object(params))
        guard let id = result["sessionId"]?.string else { throw ACPError.server(code: 0, message: "session/new 没有回会话 id") }
        adopt(id, in: directory, result)
    }

    /// 接着一个已结束的会话（`session/load`）：Agent 重放的历史不算。
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

    /// 上桥（托管会话）。
    func attach(_ session: PiSession) {
        id = session.id
        var session = session
        publishOptions(to: &session)
        bridge?.attach(session, via: self)
    }

    /// 等 CuePad 的 MCP 服务连上（`ACPDialect.connectsMCPLater`）。
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

    // MARK: 配置项

    /// 配置项里某一类的那一项（`model`、`thought_level`）
    func option(_ category: String) -> JSONValue? { options.first { $0["category"]?.string == category } }

    /// 一项的可选值：平铺的，或分组的（每组的 `options`）
    private func values(_ option: JSONValue?) -> [JSONValue] {
        (option?["options"]?.array ?? []).flatMap { $0["options"]?.array ?? [$0] }
    }

    var currentModel: String? { option("model")?["currentValue"]?.string }
    var currentLevel: PiThinkingLevel? { option("thought_level")?["currentValue"]?.string.flatMap(PiThinkingLevel.init(rawValue:)) }
    var levels: [PiThinkingLevel] { values(option("thought_level")).compactMap { $0["value"]?.string.flatMap(PiThinkingLevel.init(rawValue:)) } }

    /// 可选的模型（强度是在用模型的那几档）
    var models: [PiModelOption] {
        values(option("model")).compactMap { value in
            value["value"]?.string.map { PiModelOption(key: key($0), name: value["name"]?.string ?? $0, thinkingLevels: levels) }
        }
    }

    /// 在用的模型：按完整的模型键对（模型写成 `提供方/模型` 的家，只对 id 会认错或认不出）
    var currentOption: PiModelOption? { currentModel.flatMap { current in models.first { $0.key == key(current) } } }

    /// 配置项里的模型值读成模型键（`AgentKind.modelKey`；下发时反过来写成 `AgentKind.modelRef`）
    func key(_ model: String) -> PiModelKey { agent.modelKey(model) ?? PiModelKey(provider: "", id: model) }

    /// 换掉一项（`session/set_config_option`）：Agent 不认这个值时抛 `ACPError.server`，在用的不变。
    func set(_ category: String, to value: String) async throws {
        guard let sessionID, let config = option(category)?["id"]?.string else { throw HostedSessionError.rejected(String(localized: "\(agent.name) 不能换这一项")) }
        let result = try await live.call("session/set_config_option", ["sessionId": .string(sessionID), "configId": .string(config), "value": .string(value)])
        if let updated = result["configOptions"]?.array { adopt(options: updated) }
    }

    /// 就地换模型、强度（强度夹到换完之后的模型有的档位）；记下换过的，开新会话后再交一次（`HostedSession.configure`）。
    func configure(model: String?, effort: PiThinkingLevel?) async throws {
        if let model { try await set("model", to: model) }
        if let effort { try await set("thought_level", to: effort.clamped(to: levels).rawValue) }
        configured = (model ?? configured.model, effort ?? configured.effort)
    }

    private func adopt(options updated: [JSONValue]) {
        options = updated
        contextWindow = currentModel.flatMap { dialect.window(of: $0, in: opened) } ?? contextWindow
        guard let id else { return }
        bridge?.update(id) { publishOptions(to: &$0) }
    }

    private func publishOptions(to session: inout PiSession) {
        session.availableModels = models
        session.model = currentOption
        session.thinking = currentLevel.map(Open.known)
    }

    // MARK: 一轮

    /// 以这句开一轮（不等模型）：回应到了这一轮结束。
    func prompt(_ blocks: [JSONValue], deliveryID: String? = nil) throws {
        let connection = try live
        guard let sessionID else { throw HostedSessionError.notRunning }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "prompt": .array(blocks)]
        if let meta = dialect.promptMeta(deliveryID: deliveryID) { params["_meta"] = meta }
        let mine = begin()
        Task { [weak self] in
            do {
                try await connection.call("session/prompt", .object(params), timed: false)
                self?.finish(mine, failure: nil)
            } catch ACPError.closed {
                // 进程退出：由 `ended` 收尾
            } catch ACPError.server(_, let message) {
                self?.finish(mine, failure: message)
            } catch {
                self?.finish(mine, failure: error.localizedDescription)
            }
        }
    }

    /// 停下在跑的这一轮，等它结束；歇着什么都不做。
    func interrupt() async throws {
        guard facts.running, let sessionID else { return }
        stopping = true
        decline()
        try live.notify("session/cancel", ["sessionId": .string(sessionID)])
        await untilFinished()
    }

    /// 等这一轮结束（没在跑立即返回）。
    func untilFinished() async {
        guard facts.running else { return }
        await withCheckedContinuation { closing.append($0) }
    }

    private func begin() -> Int {
        turn += 1
        facts.startTurn(at: .now)
        speak(nil)
        emit(.turnStarted)
        publish()
        return turn
    }

    /// 这一轮结束；`which` 是 `session/prompt` 开的那一轮的编号（别的轮的回应不算），nil 是各家报的结束。
    private func finish(_ which: Int?, failure: String?) {
        guard facts.running, which.map({ $0 == turn }) ?? true else { return }
        let stopped = stopping
        stopping = false
        if stopped || failure != nil { speak(nil) }
        decline()
        let failure = stopped ? nil : failure
        facts.endTurn(failure: failure)
        if let failure { emit(.failed(failure)) }
        emit(.turnFinished)
        release()
        publish()
    }

    private func release() {
        closing.forEach { $0.resume() }
        closing = []
    }

    /// 没答的作废（`ACPAsk.withdrawn`）。
    private func decline() {
        guard let pending else { return }
        self.pending = nil
        facts.questions = []
        connection?.respond(to: pending.request, result: pending.ask.withdrawn)
    }

    /// 等你回答这一问（同一请求的下一问也经这里）。
    func present(_ ask: ACPAsk, request: JSONValue) {
        var ask = ask
        ask.question.promptID = UUID().uuidString
        pending = (request, ask)
        facts.questions = [ask.question]
        publish()
    }

    // MARK: 一处产出

    /// 交给事件流（大脑）与桥（托管会话）。
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

    // MARK: 收

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
        case .turnStarted: if !facts.running { _ = begin() }
        case .turnFinished(let failure): finish(nil, failure: failure)
        case .context(let used): noteContext(used: used, window: contextWindow)
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

    /// 进程退出：在等的全部放行；托管会话下桥，大脑报退出。
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

#if os(macOS)
import CueStore
import CueText
import Foundation

/// 没在跑时来的 `result`（大脑的 `/clear`、子代理交回时的空转）不报成一轮。后台任务落定后什么时候算歇下见 `ClaudeHostedTasks`。
/// 上下文用量取模型回答带的 `usage`：为 0 的是 Claude Code 合成的回答（报错等），不算；`result` 的用量是整轮累加的、停在模型回话之前时全是 0，不用。
/// 托管会话的发话与斜杠命令是先停下（`interrupt`）再送进去开新一轮（`HostedTurns.send`）；
/// 不用 `priority: "now"`：前台工具跑着时它不中止，等工具跑完并进这一轮（实测 2.1.299，各权限模式）。
/// 大脑（不挂桥）与其余控制请求一律回错误，免得这一轮卡住。
/// 托管会话的权限模式固定 auto（同终端里 Claude Code 的内置默认），所以不另设模式开关：用户的 allow / deny / ask 规则照旧生效。
/// 结束、空闲满时限、让出（桥决定）都经 `end` 下桥、收进程（`HostedProcesses`），后两者不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    private(set) weak var bridge: Bridge?
    private(set) weak var processes: HostedProcesses?
    let brain: BrainSession?
    private(set) var stream: ClaudeStream?
    private(set) var id: Session.ID?
    let turns: HostedTurns
    var tasks = ClaudeHostedTasks()
    var permission: (request: String, permission: ClaudePermission)?
    let deliveries = ClaudeDelivery()
    /// 大脑在做的 `/clear`，先发的在前：每个 `result` 结束最早的那个等待
    var clearing: [UUID] = []
    let clearWaits: PendingReplies<UUID, Void>
    private var apiError: String?
    /// 报过的上下文用量（`TurnEvent.context`）：用量随每条回答来，窗口到这一轮收尾（`result` 的 `modelUsage`）才知道
    private var contextUsed: Int?
    private var contextWindow: Int?
    /// 模型目录里每项（别名，如 `haiku`）解析到的 id（`claude-haiku-5-5`）：每轮报的是后者，界面认前者
    private var resolved: [String: String] = [:]

    let timing: Timing

    init(bridge: Bridge, processes: HostedProcesses, timing: Timing) {
        self.bridge = bridge
        self.processes = processes
        self.timing = timing
        brain = nil
        turns = HostedTurns(timing: timing)
        clearWaits = Self.clearWaits(timing)
        turns.onSettle = { [weak self] in self?.publish(at: .now) }
    }

    init(timing: Timing) {
        self.timing = timing
        brain = BrainSession(agent: .claudeCode)
        turns = HostedTurns(timing: timing)
        clearWaits = Self.clearWaits(timing)
    }

    private static func clearWaits(_ timing: Timing) -> PendingReplies<UUID, Void> {
        PendingReplies(timeout: AgentTimeouts.stop, timing: timing, timeoutError: BridgeError.ackTimeout)
    }

    /// 起好的连接；没起或起不来时抛 `sessionEnded`（进程退出后写入同样抛它）
    var live: ClaudeStream {
        get throws {
            guard let stream else { throw BridgeError.sessionEnded }
            return stream
        }
    }

    func launch(
        _ executable: URL, _ arguments: [String], directory: URL, environment: [String: String], timing: Timing
    ) async throws -> ChildProcess {
        let stream = try await ClaudeStream(executable: executable, arguments: arguments, directory: directory, environment: environment, timing: timing)
        self.stream = stream
        stream.onMessage = { [weak self] in self?.received($0) }
        stream.onDraft = { [weak self] in self?.emit(.speaking($0)) }
        stream.onClose = { [weak self] in self?.ended() }
        return stream.process
    }

    /// 接着已结束的会话时 `known` 是索引里记下的名字与首条消息，`model` 是起进程时指定的模型（几个别名解析到同一个 id 时，之后报的 id 认回它）。
    func connect(
        sessionID: String, cwd: URL, sessionFile: URL, model: ModelKey?, launchToken: String?, known: (name: String?, firstMessage: String?)?
    ) async throws -> Session {
        let stream = try live
        let info = try await stream.request(["subtype": "initialize"])
        let offered = ClaudeCode.models(in: info)
        for model in offered { resolved[model.option.key.id] = model.resolved }
        let models = offered.map(\.option)
        let listed = (info["commands"]?.array ?? []).compactMap { command -> SlashCommand? in
            guard let name = command["name"]?.string else { return nil }
            let hint = command["argumentHint"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return SlashCommand(
                name: name, summary: command["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.builtin), hint: hint)
        }
        let pid = stream.process.pid
        var session = Session(
            id: Session.claudeID(sessionID: sessionID, pid: pid), sessionID: sessionID, agent: .claudeCode, sessionFile: sessionFile, pid: pid,
            cwd: cwd, state: .settled, stateSince: .now)
        session.launchToken = launchToken
        session.name = known?.name
        session.firstMessage = known?.firstMessage
        session.availableModels = models
        session.model = models.first { $0.key == model }
        session.commands = listed
        id = session.id
        bridge?.attach(session, via: self)
        return session
    }

    /// `HostedTurns` 不认的（已在跑时的开始、没在跑时的工具与收尾）不往外报。
    func emit(_ event: TurnEvent, at time: Date = .now) {
        guard turns.apply(event, at: time) else { return }
        brain?.emit(event)
        if let id { bridge?.show(event, in: id) }
    }

    private func noteContext(used: Int?, window: Int?) {
        guard let used, used != contextUsed || window != contextWindow else { return }
        contextUsed = used
        contextWindow = window
        emit(.context(used: used, window: window))
    }

    private func received(_ message: JSONValue) {
        deliveries.observe(message)
        let now = Date.now
        let main = message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null
        switch message["type"]?.string {
        case "control_request":
            asked(message)
        case "control_cancel_request":
            guard message["request_id"]?.string == permission?.request else { return }
            permission = nil
            turns.facts.questions = []
        case "system":
            system(message, at: now)
        case "assistant" where main:
            answered(message)
        case "user" where main:
            for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                emit(.toolDone(id: block["tool_use_id"]?.string ?? "", result: brainText(block["content"]), failed: block["is_error"]?.bool == true))
            }
        case "result":
            result(message, at: now)
        case "command_lifecycle" where message["state"]?.string == "started":
            emit(.turnStarted)
            if let id = message["command_uuid"]?.string.flatMap(UUID.init(uuidString:)) { emit(.received(id)) }
        default:
            return
        }
        publish(at: now)
    }

    private func asked(_ message: JSONValue) {
        guard let request = message["request_id"]?.string else { return }
        guard bridge != nil, message["request"]?["subtype"]?.string == "can_use_tool" else {
            try? stream?.write(["type": "control_response", "response": ["subtype": "error", "request_id": .string(request), "error": "CuePad does not handle this request"]])
            return
        }
        let ask = ClaudePermission(tool: message["request"]?["tool_name"]?.string ?? "?", input: message["request"]?["input"] ?? .object([:]))
        permission = (request, ask)
        turns.facts.questions = [ask.question()]
    }

    private func answered(_ message: JSONValue) {
        if let usage = message["message"]?["usage"] {
            let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage[$0]?.int }.reduce(0, +)
            if used > 0 { noteContext(used: used, window: contextWindow) }
        }
        // 这一轮出错时 Claude Code 合成一条带错误类型的回答（`is_api_error_message`），原话就是对话里的那条
        if message["is_api_error_message"]?.bool == true, let code = message["error"]?.string {
            apiError = ClaudeCode.failure(
                code: code, status: message["api_error_status"]?.int,
                message: (message["message"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n"))
        }
        for block in message["message"]?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "tool_use":
                emit(.tool(id: block["id"]?.string ?? "", name: block["name"]?.string ?? "?", arguments: String(decoding: (block["input"] ?? [:]).data, as: UTF8.self)))
            case "thinking": turns.facts.work(.thinking)
            default: break
            }
        }
    }

    private func result(_ message: JSONValue, at now: Date) {
        // 一轮在跑时的 `result` 是那一轮的；`/clear` 的回应在歇着时来，为通知跑的那一轮歇着时也可能来
        if !tasks.answered(message), !turns.running { endClear(.success(())) }
        var window = contextWindow
        for usage in (message["modelUsage"]?.object ?? [:]).values {
            if let reported = usage["contextWindow"]?.int { window = reported }
        }
        noteContext(used: contextUsed, window: window)
        let stopped = turns.stopping
        permission = nil
        // 被停下的一轮不一定标出错（那时 `ClaudeStream` 才清掉正在说的话）
        if stopped { emit(.speaking(nil)) }
        let failure = stopped ? nil : failure(of: message)
        if let failure {
            deliveries.failed(failure, in: message)
            emit(.failed(failure))
        }
        emit(.turnFinished)
        apiError = nil
        if let owed = tasks.owedSince { emit(.turnStarted, at: owed) }
    }

    private func failure(of result: JSONValue) -> String? {
        guard result["is_error"]?.bool == true || apiError != nil else { return nil }
        let errors = (result["errors"]?.array?.compactMap(\.string) ?? []).joined(separator: "\n")
        return [apiError, result["result"]?.string, errors].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? result["subtype"]?.string ?? String(localized: "未知错误")
    }

    /// 几个别名可能解析到同一个 id，所以先认当前选的那项；都对不上才显示原始 id。
    private func option(_ model: String, current: ModelOption?, in catalog: [ModelOption]) -> ModelOption {
        let matches = { (option: ModelOption) in option.key.id == model || self.resolved[option.key.id] == model }
        if let current, matches(current) { return current }
        return catalog.first { $0.key.id == model } ?? catalog.first(where: matches) ?? ClaudeCode.model(model)
    }

    private func system(_ message: JSONValue, at now: Date) {
        switch message["subtype"]?.string {
        case "init":
            if let model = message["model"]?.string, let id {
                bridge?.update(id) { session in session.model = self.option(model, current: session.model, in: session.availableModels) }
            }
        case "background_tasks_changed":
            tasks.list(message["tasks"]?.array ?? [])
            turns.facts.inFlight = tasks.inFlight
        case "status":
            if ClaudeStream.requestsModel(message) { emit(.turnStarted) }
            turns.facts.compacting = message["status"]?.string == "compacting"
        case "session_title_changed":
            if let title = message["title"]?.string, let id { bridge?.update(id) { $0.name = title } }
        case "task_started":
            // 后台跑的命令（`local_bash`）也报成任务，不是子代理
            guard let task = message["task_id"]?.string, message["task_type"]?.string == "local_agent" else { return }
            turns.facts.runSubagent(task, name: message["description"]?.string ?? "", role: message["subagent_type"]?.string ?? "", at: now)
        case "task_updated":
            if let task = message["task_id"]?.string, let end = message["patch"]?["end_time"]?.number { tasks.ended(task, at: end) }
        case "task_progress":
            if let task = message["task_id"]?.string, let action = message["description"]?.string {
                turns.facts.updateSubagent(task, at: now) { $0.action = action.clipped(ToolDetail.limit) }
            }
        case "task_notification":
            guard let task = message["task_id"]?.string else { return }
            let phase: SubagentPhase = switch message["status"]?.string {
            case "completed": .done
            case "failed": .failed
            default: .interrupted
            }
            turns.facts.settleSubagent(task, phase, summary: message["summary"]?.string, at: now)
            if let start = tasks.settled(task, run: message["run_id"]?.string, completed: phase == .done, at: now) { emit(.turnStarted, at: start) }
            turns.facts.inFlight = tasks.inFlight
        default:
            break
        }
    }

    func publish(at now: Date) {
        guard let id else { return }
        bridge?.update(id) { turns.facts.publish(to: &$0, at: now) }
    }

    private func ended() {
        deliveries.close()
        turns.closed()
        closeClears()
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
        if let brain, let process = stream?.process {
            Task { brain.exited(await process.exited()) }
        }
    }
}
#endif

#if os(macOS)
import CueAgent
import CueStore
import CueText
import Foundation

/// 没在跑时来的 `result`（大脑的 `/clear`、子代理交回时的空转）不报成一轮。
/// 上下文用量取模型回答带的 `usage`：为 0 的是 Claude Code 合成的回答（报错等），不算；`result` 的用量是整轮累加的、停在模型回话之前时全是 0，不用。
/// 停下（`interrupt`）：发出的话还没等到 `system/init` 时中断不起作用（实测 2.1.299），先等它开跑。托管会话的发话与斜杠命令是先停下再送进去开新一轮，被停下的那一轮不算歇下；
/// 不用 `priority: "now"`：前台工具跑着时它不中止，等工具跑完并进这一轮（实测 2.1.299，各权限模式）。
/// 大脑（不挂桥）与其余控制请求一律回错误，免得这一轮卡住。
/// 托管会话的权限模式固定 auto（同终端里 Claude Code 的内置默认），所以不另设模式开关：用户的 allow / deny / ask 规则照旧生效。它自己也会跑用户装的钩子（`ClaudeCodeRuntime` 按进程认出来直接放行，不重复登记）。
/// 退出靠关标准输入（读到 EOF 正常收尾）；结束、空闲满时限、让出（桥决定）都这样退，后两者不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    private(set) weak var bridge: PiBridge?
    let brain: BrainSession?
    private(set) var stream: ClaudeStream?
    private(set) var id: PiSession.ID?
    var facts = SessionFacts()
    var tasks = ClaudeHostedTasks()
    var permission: (request: String, permission: ClaudePermission)?
    var commands: Set<String> = []
    let deliveries = ClaudeDelivery()
    /// 停下这一轮（停止或发来新的一句）后的 `result` 是被打断的，不算出错
    var stopping = false
    /// 为送进一句话停下这一轮：被停下的这一轮的 `result` 不算歇下，接着就是这句开的新一轮（从这一刻算）
    var restart = false
    /// 等着这一轮收尾（`result`）的停下；进程退出时也放行，对端不发 `result` 时到 `AgentTimeouts.stop` 放弃
    let closing: PendingReplies<UUID, Void>
    let stopPhase = StopPhase()
    /// 收尾过的轮数：停下时据此认出它在等回应的工夫里已经收尾
    var closed = 0
    var starting = false
    /// 等 `init` 的停止挂在这里，这一轮开跑或结束时放行；对端不发 `init` 时到 `AgentTimeouts.stop` 放弃
    let startWaits: PendingReplies<UUID, Void>
    /// 大脑在做的 `/clear`，先发的在前：每个 `result` 结束最早的那个等待
    var clearing: [UUID] = []
    let clearWaits: PendingReplies<UUID, Void>
    private var apiError: String?
    /// 报过的上下文用量（`TurnEvent.context`）：用量随每条回答来，窗口到这一轮收尾（`result` 的 `modelUsage`）才知道
    private var contextUsed: Int?
    private var contextWindow: Int?
    /// 模型目录里每项（别名，如 `haiku`）解析到的 id（`claude-haiku-5-5`）：每轮报的是后者，界面认前者
    private var resolved: [String: String] = [:]

    /// 等收尾的时限与进程收尾的宽限（`ChildProcess.stop()`）都按 `timing` 量
    let timing: Timing

    init(bridge: PiBridge, timing: Timing) {
        self.bridge = bridge
        self.timing = timing
        brain = nil
        (closing, startWaits, clearWaits) = Self.waits(timing)
    }

    init(timing: Timing) {
        self.timing = timing
        brain = BrainSession()
        (closing, startWaits, clearWaits) = Self.waits(timing)
    }

    private static func waits(_ timing: Timing) -> (PendingReplies<UUID, Void>, PendingReplies<UUID, Void>, PendingReplies<UUID, Void>) {
        func table() -> PendingReplies<UUID, Void> { PendingReplies(timeout: AgentTimeouts.stop, timing: timing, timeoutError: PiBridgeError.ackTimeout) }
        return (table(), table(), table())
    }

    /// 起好的连接；没起或起不来时抛 `sessionEnded`（进程退出后写入同样抛它）
    var live: ClaudeStream {
        get throws {
            guard let stream else { throw PiBridgeError.sessionEnded }
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
        sessionID: String, cwd: URL, sessionFile: URL, model: PiModelKey?, launchToken: String?, known: (name: String?, firstMessage: String?)?
    ) async throws -> PiSession {
        let stream = try live
        let info = try await stream.request(["subtype": "initialize"])
        let offered = ClaudeCode.models(in: info)
        for model in offered { resolved[model.option.key.id] = model.resolved }
        let models = offered.map(\.option)
        let listed = (info["commands"]?.array ?? []).compactMap { command -> PiSlashCommand? in
            guard let name = command["name"]?.string else { return nil }
            let hint = command["argumentHint"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return PiSlashCommand(
                name: name, summary: command["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.builtin), hint: hint)
        }
        commands = Set(listed.map(\.name))
        let pid = stream.process.pid
        var session = PiSession(
            id: PiSession.claudeID(sessionID: sessionID, pid: pid), sessionID: sessionID, agent: .claudeCode, sessionFile: sessionFile, pid: pid,
            cwd: cwd, terminal: PiTerminal(), state: .settled, stateSince: .now)
        session.hosted = true
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

    private func emit(_ event: TurnEvent) {
        brain?.emit(event)
        if let id { bridge?.show(event, in: id) }
    }

    private func startTurn(at now: Date) {
        facts.startTurn(at: now)
        emit(.turnStarted)
    }

    private func finishTurn(failure: String?) {
        let ran = facts.running
        facts.endTurn(failure: failure)
        guard ran else { return }
        if let failure { emit(.failed(failure)) }
        emit(.turnFinished)
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
            facts.questions = []
        case "system":
            system(message, at: now)
        case "assistant" where main:
            answered(message)
        case "user" where main:
            if facts.activity == .tool { facts.work(.thinking) }
            for block in message["message"]?["content"]?.array ?? [] where facts.running && block["type"]?.string == "tool_result" {
                emit(.toolDone(id: block["tool_use_id"]?.string ?? "", result: brainText(block["content"]), failed: block["is_error"]?.bool == true))
            }
        case "result":
            result(message, at: now)
        case "command_lifecycle" where message["state"]?.string == "started":
            beginTurn()
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
        facts.questions = [ask.question()]
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
                let name = block["name"]?.string ?? "?"
                facts.work(.tool, detail: ToolDetail.line(name, block["input"]))
                emit(.tool(id: block["id"]?.string ?? "", name: CueMCPServer.bareName(name, on: .claudeCode), arguments: String(decoding: (block["input"] ?? [:]).data, as: UTF8.self)))
            case "thinking": facts.work(.thinking)
            default: break
            }
        }
    }

    private func result(_ message: JSONValue, at now: Date) {
        // 一轮在跑时的 `result` 是那一轮的；`/clear` 的回应在歇着时来
        if !facts.running { endClear(.success(())) }
        var window = contextWindow
        for usage in (message["modelUsage"]?.object ?? [:]).values {
            if let reported = usage["contextWindow"]?.int { window = reported }
        }
        noteContext(used: contextUsed, window: window)
        let stopped = stopping
        stopping = false
        permission = nil
        // 被停下的一轮不一定标出错（那时 `ClaudeStream` 才清掉正在说的话）
        if stopped { emit(.speaking(nil)) }
        let failure = stopped ? nil : failure(of: message)
        if let failure { deliveries.failed(failure, in: message) }
        finishTurn(failure: failure)
        apiError = nil
        started()
        if restart {
            restart = false
            startTurn(at: now)
            starting = true
        }
        closed += 1
        release()
    }

    private func failure(of result: JSONValue) -> String? {
        guard result["is_error"]?.bool == true || apiError != nil else { return nil }
        let errors = (result["errors"]?.array?.compactMap(\.string) ?? []).joined(separator: "\n")
        return [apiError, result["result"]?.string, errors].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? result["subtype"]?.string ?? String(localized: "未知错误")
    }

    /// 几个别名可能解析到同一个 id，所以先认当前选的那项；都对不上才显示原始 id。
    private func option(_ model: String, current: PiModelOption?, in catalog: [PiModelOption]) -> PiModelOption {
        let matches = { (option: PiModelOption) in option.key.id == model || self.resolved[option.key.id] == model }
        if let current, matches(current) { return current }
        return catalog.first { $0.key.id == model } ?? catalog.first(where: matches) ?? ClaudeCode.model(model)
    }

    private func system(_ message: JSONValue, at now: Date) {
        switch message["subtype"]?.string {
        case "init":
            started()
            if let model = message["model"]?.string, let id {
                bridge?.update(id) { session in session.model = self.option(model, current: session.model, in: session.availableModels) }
            }
        case "background_tasks_changed":
            tasks.list(message["tasks"]?.array ?? [])
            facts.inFlight = tasks.inFlight
        case "status":
            if ClaudeStream.requestsModel(message) { beginTurn() }
            facts.compacting = message["status"]?.string == "compacting"
        case "session_title_changed":
            if let title = message["title"]?.string, let id { bridge?.update(id) { $0.name = title } }
        case "task_started":
            // 后台跑的命令（`local_bash`）也报成任务，不是子代理
            guard let task = message["task_id"]?.string, message["task_type"]?.string == "local_agent" else { return }
            facts.runSubagent(task, name: message["description"]?.string ?? "", role: message["subagent_type"]?.string ?? "", at: now)
        case "task_progress":
            if let task = message["task_id"]?.string, let action = message["description"]?.string {
                facts.updateSubagent(task, at: now) { $0.action = action.clipped(ToolDetail.limit) }
            }
        case "task_notification":
            guard let task = message["task_id"]?.string else { return }
            let phase: PiSubagentPhase = switch message["status"]?.string {
            case "completed": .done
            case "failed": .failed
            default: .interrupted
            }
            facts.settleSubagent(task, phase, summary: message["summary"]?.string, at: now)
            if tasks.settled(task, completed: phase == .done) { beginTurn() }
            facts.inFlight = tasks.inFlight
        default:
            break
        }
    }

    /// 开始时刻是此刻：发出话的那一刻、收到开它的 `task_notification` 或它开始请求模型的那一刻，都早于这一轮的回答。
    func beginTurn() {
        if !facts.running { startTurn(at: .now) }
    }

    func publish(at now: Date) {
        guard let id else { return }
        bridge?.update(id) { facts.publish(to: &$0, at: now) }
    }

    private func ended() {
        deliveries.close()
        started()
        release()
        closeClears()
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
        if let brain, let process = stream?.process {
            Task { brain.exited(await process.exited()) }
        }
    }
}
#endif

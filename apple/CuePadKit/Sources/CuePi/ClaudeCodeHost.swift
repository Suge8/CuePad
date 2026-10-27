#if os(macOS)
import CueAgent
import CueStore
import CueText
import Foundation

/// CuePad 起的一个 `claude` 进程，以 stream-json 收发（与 Agent SDK 同一套线协议，`ClaudeStream`），没有终端界面。两种开法，同一套一轮的状态：
/// - 托管会话（`init(bridge:)` → `host` → `connect`）：上桥、进会话列表，发话（带图）、斜杠命令、停止、换模型与强度、改名、作答、结束（+Control）；
/// - Cue 的大脑（`init()` → `start`，`HostedSession`，见 +Brain）：不上桥，只产出事件流，启动参数与发话语义见那里。
///
/// 一轮的起止、工具、上下文、正在说的话都在这里判一次，从同一处交给两边：事件（`emit`，大脑的事件流）与桥上的事实（`facts`、草稿、上下文）。
/// - 一轮从发出话或它开始请求模型（`ClaudeStream.requestsModel`）起，到 `result` 止，被停下的照常结束、不算出错；
///   没在跑时来的 `result`（大脑的 `/clear`、子代理交回时的空转）不报成一轮。在飞的工作见 `ClaudeHostedTasks`，正在说的话由 `ClaudeStream` 得出。
/// - 上下文用量：最近一次调模型（模型回答带的 `usage`）的输入合计——`input_tokens` 加缓存的读与写，不含输出（同 `TurnEvent.context`）；
///   为 0 的是 Claude Code 合成的回答（报错等），不算。`result` 的用量是整轮累加的、停在模型回话之前时全是 0，不用；窗口从它的模型用量里来，只给桥。
/// - 停下（`interrupt`）：在跑就发 `interrupt` 控制请求（连同在跑的工具）并等它收尾（`result`）；发出的话还没等到 `system/init` 时
///   中断不起作用（实测 2.1.299），先等它开跑。托管会话的发话与斜杠命令是先停下再送进去开新一轮，被停下的那一轮不算歇下；
///   不用 `priority: "now"`：前台工具跑着时它不中止，等工具跑完并进这一轮（实测 2.1.299，各权限模式）。
/// - 它问的事：托管会话的 `can_use_tool` 成为 CuePad 里的确认；大脑（不挂桥）与其余控制请求一律回错误，免得这一轮卡住。
/// - 托管会话的权限模式固定 auto（同终端里 Claude Code 的内置默认）：由它的分类器放行或拦下（拦下的告诉模型原因，不问人）；
///   仍要人点头的（用户的 ask 规则、连续被拦到阈值、auto 用不了时整场退回 Manual）经 `can_use_tool` 问。用户的 allow / deny / ask 规则照旧生效，
///   所以不另设模式开关。它自己也会跑用户装的钩子（`ClaudeCodeRuntime` 按进程认出来直接放行，不重复登记）。
/// - 退出靠关标准输入（读到 EOF 正常收尾）；结束、空闲满时限、让出（桥决定）都这样退，后两者不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    /// 托管会话挂的桥；大脑没有
    private(set) weak var bridge: PiBridge?
    /// 大脑的事件流与临时目录；托管会话没有（没人订阅）
    let brain: BrainSession?
    private(set) var stream: ClaudeStream?
    /// 上了桥之后的 id（`initialize` 回来之前、大脑为 nil）
    private(set) var id: PiSession.ID?
    var facts = SessionFacts()
    var tasks = ClaudeHostedTasks()
    /// 在等的 `can_use_tool`（请求 id 与问题）
    var permission: (request: String, permission: ClaudePermission)?
    var commands: Set<String> = []
    /// 停下这一轮（停止或发来新的一句）后的 `result` 是被打断的，不算出错
    private var stopping = false
    /// 为送进一句话停下这一轮：被停下的这一轮的 `result` 不算歇下，接着就是这句开的新一轮（从这一刻算）
    private var restart = false
    /// 等着这一轮收尾（`result`）的停下；进程退出时也放行
    private var closing: [CheckedContinuation<Void, Never>] = []
    /// 收尾过的轮数：停下时据此认出它在等回应的工夫里已经收尾
    private var closed = 0
    /// 发出的话开了一轮、还没等到它的 `system/init`：等 `init` 的停止挂在这里，这一轮开跑或结束时放行
    private var starting: [CheckedContinuation<Void, Never>]?
    /// 大脑的 `/clear` 在做：它的 `result` 回来时结束等待
    var clearing: CheckedContinuation<Void, any Error>?
    /// 这一轮里 Claude Code 合成的出错回答（`ClaudeCode.failure` 的原文）；一轮结束时清掉
    private var apiError: String?
    /// 报过的上下文用量（`TurnEvent.context`）：用量随每条回答来，窗口到这一轮收尾（`result` 的 `modelUsage`）才知道
    private var contextUsed: Int?
    private var contextWindow: Int?
    /// 模型目录里每项（别名，如 `haiku`）解析到的 id（`claude-haiku-5-5`）：每轮报的是后者，界面认前者
    private var resolved: [String: String] = [:]

    /// 托管会话：`host` 起进程、`connect` 上桥。
    init(bridge: PiBridge) {
        self.bridge = bridge
        brain = nil
    }

    /// Cue 的大脑：`start` 起进程。
    init() {
        brain = BrainSession()
    }

    /// 起好的连接；没起或起不来时抛 `sessionEnded`（进程退出后写入同样抛它）
    var live: ClaudeStream {
        get throws {
            guard let stream else { throw PiBridgeError.sessionEnded }
            return stream
        }
    }

    /// 起进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    func launch(_ executable: URL, _ arguments: [String], directory: URL, environment: [String: String]) async throws -> ChildProcess {
        let stream = try await ClaudeStream(executable: executable, arguments: arguments, directory: directory, environment: environment)
        self.stream = stream
        stream.onMessage = { [weak self] in self?.received($0) }
        stream.onDraft = { [weak self] in self?.emit(.speaking($0)) }
        stream.onClose = { [weak self] in self?.ended() }
        return stream.process
    }

    /// 托管会话起进程：权限确认经标准输入问 CuePad，模式 auto（见类注释）。
    func host(executable: URL, arguments: [String], directory: URL, environment: [String: String]) async throws -> ChildProcess {
        try await launch(
            executable, ["--permission-prompt-tool", "stdio", "--permission-mode", "auto"] + arguments, directory: directory, environment: environment)
    }

    /// 握手（`initialize` 拿到可换的模型与命令）并上桥；接着已结束的会话时 `known` 是索引里记下的名字与首条消息，
    /// `model` 是起进程时指定的模型（几个别名解析到同一个 id 时，之后报的 id 认回它）。
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

    // MARK: 一处产出

    /// 交给事件流（大脑）与桥（托管会话）。
    private func emit(_ event: TurnEvent) {
        brain?.emit(event)
        guard let id, let bridge else { return }
        switch event {
        case .speaking(let draft): bridge.setDraft(id, draft)
        case .context(let used, let window?): bridge.update(id) { $0.context = PiContextUsage(tokens: used, window: window) }
        default: break
        }
    }

    private func startTurn(at now: Date) {
        facts.startTurn(at: now)
        emit(.turnStarted)
    }

    /// 这一轮结束；没在跑时（见类注释）只记下出错，不报成一轮。
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

    // MARK: 输出

    private func received(_ message: JSONValue) {
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

    /// 主会话的一条模型回答（一行一块）：用量、合成的出错、工具调用与思考。
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
        clearing?.resume()
        clearing = nil
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
        finishTurn(failure: stopped ? nil : failure(of: message))
        apiError = nil
        started()
        if restart {
            restart = false
            startTurn(at: now)
            starting = []
        }
        closed += 1
        release()
    }

    /// 这一轮出错的原文：合成的出错回答优先，再是 `result` 的原话、它列的错误；没出错为 nil。
    private func failure(of result: JSONValue) -> String? {
        guard result["is_error"]?.bool == true || apiError != nil else { return nil }
        let errors = (result["errors"]?.array?.compactMap(\.string) ?? []).joined(separator: "\n")
        return [apiError, result["result"]?.string, errors].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? result["subtype"]?.string ?? String(localized: "未知错误")
    }

    /// 这一轮报的模型 id 对应的目录项：先认当前选的那项（几个别名可能解析到同一个 id），再按别名、按解析后的 id 找；都对不上才显示原始 id。
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

    /// 主会话开始一轮（已在跑的不算新的一轮：发出话、后台任务落定时先算开始，随后它请求模型是同一轮）。
    /// 开始时刻是此刻：发出话的那一刻、收到开它的 `task_notification` 或它开始请求模型的那一刻，都早于这一轮的回答。
    private func beginTurn() {
        if !facts.running { startTurn(at: .now) }
    }

    func publish(at now: Date) {
        guard let id else { return }
        bridge?.update(id) { facts.publish(to: &$0, at: now) }
    }

    /// 输出读完了（进程退出）：没答的请求 `ClaudeStream` 已以会话结束收尾；托管会话下桥，大脑报退出。
    private func ended() {
        started()
        release()
        clearing?.resume(throwing: PiBridgeError.sessionEnded)
        clearing = nil
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
        if let brain, let process = stream?.process {
            Task { brain.exited(await process.exited()) }
        }
    }

    /// 送进一句话（`userMessage`）：`interrupting` 时在跑就先停下这一轮、等它收尾，否则并进这一轮。
    func say(_ message: JSONValue, interrupting: Bool) async throws {
        if interrupting { try await interrupt(restarting: true) }
        try live.write(message)
        began()
    }

    /// 一条用户消息；`extra` 是托管会话另带的（`uuid`、`priority`，见 +Control）。
    static func userMessage(_ content: JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": .null].merging(extra) { $1 })
    }

    /// 发出的话（斜杠命令也是）一定开始一轮：从发出那一刻算，不等它的 `system/init`（中间隔着钩子）；为它停下的那一轮收尾时已经开了。
    private func began() {
        if !facts.running { starting = [] }
        beginTurn()
        publish(at: .now)
    }

    /// 这一轮开跑了（或没跑就结束了）：放行等着它的停止。
    private func started() {
        starting?.forEach { $0.resume() }
        starting = nil
    }

    /// 停下在跑的这一轮并等它收尾；还没开跑的（`starting`）先等它开跑。歇着什么都不做。
    func interrupt(restarting: Bool) async throws {
        if starting != nil { await withCheckedContinuation { starting?.append($0) } }
        guard facts.running else { return }
        stopping = true
        restart = restarting
        let turn = closed
        do {
            _ = try await live.request(["subtype": "interrupt"])
        } catch {
            restart = false
            throw error
        }
        if closed == turn { await withCheckedContinuation { closing.append($0) } }
    }

    private func release() {
        closing.forEach { $0.resume() }
        closing = []
    }
}
#endif

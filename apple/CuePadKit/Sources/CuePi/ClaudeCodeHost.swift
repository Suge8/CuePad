#if os(macOS)
import CueStore
import CueText
import Foundation

/// CuePad 在后台托管的一个 Claude Code 会话：`claude` 以 stream-json 收发（与 Agent SDK 同一套线协议），没有终端界面，
/// CuePad 掌握它的全部输入输出——发话（带图）、斜杠命令、停止、换模型与强度、改名、作答、结束都能做。
///
/// - 状态来自它的输出：一轮从它开始请求模型（`ClaudeStream.requestsModel`）起到 `result` 止，其间看模型回答里的工具调用与 `can_use_tool`；在飞的工作见 `ClaudeHostedTasks`；
///   正在说的话（`PiDraft`）由 `ClaudeStream` 得出（增量累积、块说完换成定稿），这里交给桥；
///   它自己也会跑用户装的钩子（`ClaudeCodeRuntime` 按进程认出来直接放行，不重复登记）。
/// - 发话与斜杠命令：歇着就直接开始；在跑就先停下这一轮（`interrupt` 控制请求，连同在跑的工具），等它收尾（`result`）再送进去开新一轮，
///   被停下的那一轮不算歇下。不用 `priority: "now"`：前台工具跑着时它不中止，等工具跑完并进这一轮（实测 2.1.299，各权限模式）。
/// - 权限模式固定 auto（与终端里 Claude Code 的内置默认一致）：读、工作目录里的改动直接做，其余由它的分类器放行或拦下（拦下的告诉模型原因，不问人）；
///   仍要人点头的（用户的 ask 规则、连续被拦到阈值、auto 用不了时整场退回 Manual）经 `can_use_tool` 成为 CuePad 里的确认。
///   用户的 allow / deny / ask 规则照旧生效，所以不另设模式开关。
/// - 退出靠关标准输入（读到 EOF 正常收尾）；结束、空闲满时限、让出（桥决定）都这样退，后两者不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    let sessionID: String
    let stream: ClaudeStream
    weak var bridge: PiBridge?
    /// 上了桥之后的 id（`initialize` 回来之前为 nil）
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
    /// 发出的话开了一轮、还没等到它的 `system/init`（中间隔着钩子）：Claude Code 还没开始跑，这时收到的中断不起作用（实测 2.1.299）。
    /// 等 `init` 的停止挂在这里，这一轮开跑或结束时放行
    var starting: [CheckedContinuation<Void, Never>]?
    /// 这一轮里 Claude Code 合成的出错回答（`ClaudeCode.failure` 的原文）；一轮结束时清掉
    private var apiError: String?
    private var contextWindow: Int?
    /// 最近一次调模型的用量（模型回答里带的）：上下文按它算。一轮的 `result` 是整轮累加的，停在模型回话之前时全是 0，不能用
    private var lastUsage: JSONValue?
    /// 模型目录里每项（别名，如 `haiku`）解析到的 id（`claude-haiku-5-5`）：每轮报的是后者，界面认前者
    private var resolved: [String: String] = [:]

    /// 启动进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    init(executable: URL, arguments: [String], sessionID: String, directory: URL, environment: [String: String], bridge: PiBridge) async throws {
        self.sessionID = sessionID
        self.bridge = bridge
        stream = try await ClaudeStream(
            executable: executable, arguments: ["--permission-prompt-tool", "stdio", "--permission-mode", "auto"] + arguments,
            directory: directory, environment: environment)
        stream.onMessage = { [weak self] in self?.received($0) }
        stream.onDraft = { [weak self] draft in
            guard let self, let id = self.id else { return }
            self.bridge?.setDraft(id, draft)
        }
        stream.onClose = { [weak self] in self?.ended() }
    }

    var process: ChildProcess { stream.process }

    /// 握手（`initialize` 拿到可换的模型与命令）并上桥；接着已结束的会话时 `known` 是索引里记下的名字与首条消息，
    /// `model` 是起进程时指定的模型（几个别名解析到同一个 id 时，之后报的 id 认回它）。
    func connect(
        cwd: URL, sessionFile: URL, model: PiModelKey?, launchToken: String?, known: (name: String?, firstMessage: String?)?
    ) async throws -> PiSession {
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
        let pid = process.pid
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

    // MARK: 输出

    private func received(_ message: JSONValue) {
        let now = Date.now
        switch message["type"]?.string {
        case "control_request":
            guard message["request"]?["subtype"]?.string == "can_use_tool", let request = message["request_id"]?.string else { return }
            let ask = ClaudePermission(tool: message["request"]?["tool_name"]?.string ?? "?", input: message["request"]?["input"] ?? .object([:]))
            permission = (request, ask)
            facts.questions = [ask.question()]
        case "control_cancel_request":
            guard message["request_id"]?.string == permission?.request else { return }
            permission = nil
            facts.questions = []
        case "system":
            system(message, at: now)
        case "assistant":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null else { return }
            if let usage = message["message"]?["usage"] {
                lastUsage = usage
                context()
            }
            // 这一轮出错时 Claude Code 合成一条带错误类型的回答（`is_api_error_message`），原话就是对话里的那条
            if message["is_api_error_message"]?.bool == true, let code = message["error"]?.string {
                apiError = ClaudeCode.failure(
                    code: code, status: message["api_error_status"]?.int,
                    message: (message["message"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n"))
            }
            for block in message["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "tool_use": facts.work(.tool, detail: ToolDetail.line(block["name"]?.string ?? "?", block["input"]))
                case "thinking": facts.work(.thinking)
                default: break
                }
            }
        case "user":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null else { return }
            if facts.activity == .tool { facts.work(.thinking) }
        case "result":
            for usage in (message["modelUsage"]?.object ?? [:]).values {
                if let window = usage["contextWindow"]?.int { contextWindow = window }
            }
            context()
            let failed = (message["is_error"]?.bool == true || apiError != nil) && !stopping
            stopping = false
            permission = nil
            let raw = (message["errors"]?.array?.compactMap(\.string) ?? []).joined(separator: "\n")
            facts.endTurn(failure: failed ? apiError ?? message["result"]?.string ?? raw : nil)
            apiError = nil
            started()
            if restart {
                restart = false
                facts.startTurn(at: now)
                starting = []
            }
            closed += 1
            release()
        default:
            return
        }
        publish(at: now)
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
    func beginTurn() {
        if !facts.running { facts.startTurn(at: .now) }
    }

    /// 已用上下文：最近一次模型调用的输入（含缓存）加输出；窗口从 `result` 的模型用量里来。
    private func context() {
        guard let usage = lastUsage, let window = contextWindow, let id else { return }
        let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
            .compactMap { usage[$0]?.int }.reduce(0, +)
        bridge?.update(id) { $0.context = PiContextUsage(tokens: used, window: window) }
    }

    func publish(at now: Date) {
        guard let id else { return }
        bridge?.update(id) { facts.publish(to: &$0, at: now) }
    }

    /// 输出读完了（进程退出）：下桥（没答的请求 `ClaudeStream` 已以会话结束收尾）。
    private func ended() {
        started()
        release()
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
    }

    /// 送进一句话：在跑就先停下这一轮、等它收尾（见类注释）。写明 `next`：不写时缺省可能是 `later`，要等后台的工作做完才读（实测等到被停下时挪去后台的命令跑完）。
    func say(_ content: JSONValue, uuid: String) async throws {
        try await stop(restarting: true)
        try stream.write([
            "type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": .null, "session_id": "",
            "uuid": .string(uuid), "priority": "next",
        ])
        began()
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
    func stop(restarting: Bool) async throws {
        if starting != nil { await withCheckedContinuation { starting?.append($0) } }
        guard facts.running else { return }
        stopping = true
        restart = restarting
        let turn = closed
        do {
            _ = try await stream.request(["subtype": "interrupt"])
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

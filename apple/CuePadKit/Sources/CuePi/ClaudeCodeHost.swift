#if os(macOS)
import CueStore
import Foundation

/// CuePad 在后台托管的一个 Claude Code 会话：`claude` 以 stream-json 收发（与 Agent SDK 同一套线协议），没有终端界面，
/// CuePad 掌握它的全部输入输出——发话（带图）、斜杠命令、停止、换模型与强度、改名、作答、结束都能做。
///
/// - 状态来自它的输出：`session_state_changed`（要 `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS`）、模型回答里的工具调用、`can_use_tool`、`result`；
///   正在说的话（`PiDraft`）由 `ClaudeStream` 得出（增量累积、块说完换成定稿），这里交给桥；
///   它自己也会跑用户装的钩子（`ClaudeCodeRuntime` 按进程认出来直接放行，不重复登记）。
/// - 发话的 `priority`：`next` 在这一轮跑完当前工具后插进去（马上说），`later` 等这一轮做完（等它做完再说）；`now` 会打断在跑的工具，不用。
/// - 退出靠关标准输入（读到 EOF 正常收尾）；空闲满时限、或这个会话在终端里打开了（让出）时也这样退，都不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    let sessionID: String
    private let stream: ClaudeStream
    private weak var bridge: PiBridge?
    private let idleLimit: Duration
    /// 上了桥之后的 id（`initialize` 回来之前为 nil）
    private(set) var id: PiSession.ID?
    private var permission: (request: String, permission: ClaudePermission)?
    private var commands: Set<String> = []
    private var stopping = false
    private var yielding = false
    private var idleTimer: Task<Void, Never>?
    private var subagents: [(id: String, state: PiSubagentState)] = []
    private var contextWindow: Int?

    /// 启动进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    init(
        executable: URL, arguments: [String], sessionID: String, directory: URL, environment: [String: String], bridge: PiBridge,
        idleLimit: Duration
    ) throws {
        self.sessionID = sessionID
        self.bridge = bridge
        self.idleLimit = idleLimit
        stream = try ClaudeStream(
            executable: executable, arguments: ["--permission-prompt-tool", "stdio", "--permission-mode", "default"] + arguments,
            directory: directory, environment: environment.merging(["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS": "1"]) { $1 })
        stream.onMessage = { [weak self] in self?.received($0) }
        stream.onDraft = { [weak self] draft in
            guard let self, let id = self.id else { return }
            self.bridge?.setDraft(id, draft)
        }
        stream.onClose = { [weak self] in self?.ended() }
    }

    /// 托管的进程（退出原因、进程号）
    var process: LineProcess { stream.process }

    /// 握手（`initialize` 拿到可换的模型与命令）并上桥。
    func connect(cwd: URL, sessionFile: URL, launchToken: String?) async throws -> PiSession {
        let info = try await stream.request(["subtype": "initialize"])
        let models = (info["models"]?.array ?? []).compactMap { model -> PiModelOption? in
            guard let value = model["value"]?.string else { return nil }
            let levels = model["supportedEffortLevels"]?.array?.compactMap { $0.string.flatMap(PiThinkingLevel.init(rawValue:)) } ?? []
            return ClaudeCode.model(value, name: model["displayName"]?.string, levels: levels)
        }
        let listed = (info["commands"]?.array ?? []).compactMap { command -> PiSlashCommand? in
            guard let name = command["name"]?.string else { return nil }
            let hint = command["argumentHint"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return PiSlashCommand(
                name: name, summary: command["description"]?.string.map { ClaudeCode.clip($0, 120) }, source: .known(.builtin), hint: hint)
        }
        commands = Set(listed.map(\.name))
        let pid = process.pid
        var session = PiSession(
            id: PiSession.claudeID(sessionID: sessionID, pid: pid), sessionID: sessionID, agent: .claudeCode, sessionFile: sessionFile, pid: pid,
            cwd: cwd, terminal: PiTerminal(), extensionVersion: 0, state: .settled, stateSince: .now)
        session.hosted = true
        session.launchToken = launchToken
        session.availableModels = models
        session.commands = listed
        if let summary = ClaudeHistory.summary(of: sessionFile) {
            session.name = summary.name
            session.firstMessage = summary.firstMessage
        }
        id = session.id
        bridge?.attach(session, via: self)
        startIdleTimer()
        return session
    }

    // MARK: 输出

    private func received(_ message: ClaudeJSON) {
        let now = Date.now
        switch message["type"]?.string {
        case "control_request":
            guard message["request"]?["subtype"]?.string == "can_use_tool", let request = message["request_id"]?.string else { return }
            let ask = ClaudePermission(tool: message["request"]?["tool_name"]?.string ?? "?", input: message["request"]?["input"] ?? .object([:]))
            permission = (request, ask)
            update { session in
                session.question = ask.question
                session.enter(.waitingForUser, detail: ask.title, at: now)
            }
        case "control_cancel_request":
            guard message["request_id"]?.string == permission?.request else { return }
            permission = nil
            update { session in
                session.question = nil
                session.enter(.thinking, at: now)
            }
        case "system":
            system(message, at: now)
        case "assistant":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null else { return }
            if let usage = message["message"]?["usage"] { context(usage) }
            for block in message["message"]?["content"]?.array ?? [] {
                switch block["type"]?.string {
                case "tool_use": update { $0.enter(.tool, detail: ClaudeCode.toolDetail(block["name"]?.string ?? "?", block["input"]), at: now) }
                case "thinking": update { $0.enter(.thinking, at: now) }
                default: break
                }
            }
        case "user":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null else { return }
            update { session in if session.state == .tool { session.enter(.thinking, at: now) } }
        case "result":
            for usage in (message["modelUsage"]?.object ?? [:]).values {
                if let window = usage["contextWindow"]?.number { contextWindow = Int(window) }
            }
            if let usage = message["usage"] { context(usage) }
            let failed = message["is_error"]?.bool == true && !stopping
            stopping = false
            update { session in
                session.question = nil
                guard failed else { return session.enter(rested, at: now) }
                let raw = (message["errors"]?.array?.compactMap(\.string) ?? []).joined(separator: "\n")
                let text = message["result"]?.string ?? raw
                session.enter(.error, detail: PiErrorSummary(text).line, at: now)
                session.errorMessage = text
            }
            permission = nil
        default:
            break
        }
    }

    private func system(_ message: ClaudeJSON, at now: Date) {
        switch message["subtype"]?.string {
        case "init":
            if let model = message["model"]?.string {
                update { session in session.model = session.availableModels.first { $0.key.id == model } ?? ClaudeCode.model(model) }
            }
        case "session_state_changed":
            switch message["state"]?.string {
            case "running": update { session in if !session.state.isWorking, session.state != .waitingForUser { session.enter(.thinking, at: now) } }
            case "idle": update { session in if session.state != .error { session.enter(rested, at: now) } }
            default: break
            }
        case "status":
            if message["status"]?.string == "compacting" {
                update { $0.enter(.compacting, at: now) }
            } else {
                update { session in if session.state == .compacting { session.enter(.thinking, at: now) } }
            }
        case "session_title_changed":
            if let title = message["title"]?.string { update { $0.name = title } }
        case "task_started":
            // 后台跑的命令（`local_bash`）也报成任务，不是子代理
            guard let task = message["task_id"]?.string, message["task_type"]?.string == "local_agent" else { return }
            subagents.append((task, ClaudeCode.subagent(
                name: message["description"]?.string ?? "", role: message["subagent_type"]?.string ?? "", at: now)))
            publishSubagents()
        case "task_progress":
            if let task = message["task_id"]?.string, let action = message["description"]?.string {
                updateSubagent(task) { $0.action = ClaudeCode.clip(action, 120) }
            }
        case "task_notification":
            guard let task = message["task_id"]?.string else { return }
            let phase: PiSubagentPhase = switch message["status"]?.string {
            case "completed": .done
            case "failed": .failed
            default: .interrupted
            }
            updateSubagent(task) { ClaudeCode.settle(&$0, phase, summary: message["summary"]?.string, at: now) }
            update { session in if session.state == .delegating { session.enter(rested, at: now) } }
        default:
            break
        }
    }

    /// 已用上下文：最近一次模型调用的输入（含缓存）加输出；窗口从 `result` 的模型用量里来。
    private func context(_ usage: ClaudeJSON) {
        guard let window = contextWindow else { return }
        let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
            .compactMap { usage[$0]?.number }.reduce(0, +)
        update { $0.context = PiContextUsage(tokens: Int(used), window: window) }
    }

    /// 这一轮歇下时：还有在后台跑的子代理就是等子代理，否则空闲
    private var rested: PiWorkState { subagents.contains { $0.state.phase == .known(.running) } ? .delegating : .settled }

    private func updateSubagent(_ task: String, _ change: (inout PiSubagentState) -> Void) {
        guard let index = subagents.firstIndex(where: { $0.id == task }) else { return }
        change(&subagents[index].state)
        publishSubagents()
    }

    private func publishSubagents() {
        let roster = subagents.map(\.state)
        update { $0.subagents = roster }
    }

    /// 改桥上的会话，并按改完的状态管空闲计时（空闲满时限退出，让出时空闲就退）。
    private func update(_ change: (inout PiSession) -> Void) {
        guard let id, let bridge else { return }
        bridge.update(id, change)
        guard let session = bridge.session(id: id) else { return }
        if session.state.hasPendingWork {
            idleTimer?.cancel()
            idleTimer = nil
        } else if idleTimer == nil {
            startIdleTimer()
        }
    }

    private func startIdleTimer() {
        if yielding { return close() }
        idleTimer?.cancel()
        idleTimer = Task { [weak self, idleLimit] in
            guard (try? await Task.sleep(for: idleLimit)) != nil else { return }
            self?.close()
        }
    }

    /// 同一个会话在终端里打开了：空闲就马上退，正在跑一轮就等它做完再退（两边会各写各的）。
    func yield() {
        yielding = true
        if let id, bridge?.session(id: id)?.state.hasPendingWork != true { close() }
    }

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。
    func close() {
        idleTimer?.cancel()
        idleTimer = nil
        stream.closeInput()
    }

    /// 输出读完了（进程退出）：下桥（没答的请求 `ClaudeStream` 已以会话结束收尾）。
    private func ended() {
        idleTimer?.cancel()
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
    }

    private func write(_ message: ClaudeJSON) throws { try stream.write(message) }
    private func request(_ body: ClaudeJSON) async throws -> ClaudeJSON { try await stream.request(body) }

    private var busy: Bool { id.flatMap { bridge?.session(id: $0) }?.state.isTurnRunning == true }

    private func priority(_ mode: PiQueueMode) -> ClaudeJSON { .string(!busy ? "next" : mode == .steer ? "next" : "later") }

    // MARK: SessionLink

    func send(_ message: PiMessage) async throws -> PiDelivery {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw PiBridgeError.rejected("empty")
        }
        let mode = message.whenBusy ?? .followUp
        let delivered: PiDelivery = busy ? .queued(mode) : .immediate
        try write([
            "type": "user", "message": ["role": "user", "content": ClaudeStream.content(text: message.text, images: message.images)], "parent_tool_use_id": .null, "session_id": "",
            "uuid": .string(message.deliveryID ?? UUID().uuidString), "priority": priority(mode),
        ])
        // 托管进程自己的钩子不登记（见类注释），首条消息由这里记，与终端会话的 UserPromptSubmit 同一规则
        if !message.text.isEmpty {
            update { if $0.firstMessage == nil { $0.firstMessage = String(message.text.prefix(PiSessionName.firstMessageLimit)) } }
        }
        return delivered
    }

    /// 斜杠命令就是以 / 开头的一句话：托管进程会执行它（内置命令、skill、自定义命令）。
    func command(_ line: String, whenBusy: PiQueueMode?) async throws {
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let name = line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard commands.contains(name) else { throw PiBridgeError.rejected("unknown_command") }
        try write([
            "type": "user", "message": ["role": "user", "content": .string(line)], "parent_tool_use_id": .null, "session_id": "",
            "uuid": .string(UUID().uuidString), "priority": priority(whenBusy ?? .followUp),
        ])
    }

    func abort() async throws {
        guard busy else { return }
        stopping = true
        _ = try await request(["subtype": "interrupt"])
    }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        guard model != nil || thinking != nil || name != nil else { throw PiBridgeError.rejected("bad_request") }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed?.isEmpty == true { throw PiBridgeError.rejected("bad_request") }
        if let model {
            // Claude Code 换模型时先向服务端核对：只有"不支持这个模型"才是模型表里没有，别的（网络、限流、认证、余额）照原话报。
            // 兼容网关不认的模型常只回 400/404 而没有上面的短语（DeepSeek 400："…but you passed <id>"；官方 404："model: <id>"），
            // 但 400 也可能是别的原因（官方余额不足："Your credit balance is too low…"），所以 400/404 还要原文里点了这次的模型 id 才算
            do {
                _ = try await request(["subtype": "set_model", "model": .string(model.id)])
            } catch PiBridgeError.rejected(let reason) {
                let text = reason.lowercased()
                let unknown = ["unsupported model", "not found", "unknown model", "invalid model"].contains { text.contains($0) }
                    || (["api error: 400", "api error: 404"].contains { text.contains($0) } && text.contains(model.id.lowercased()))
                throw PiBridgeError.rejected(unknown ? "unknown_model" : "failed: \(reason)")
            }
            update { session in session.model = session.availableModels.first { $0.key == model } ?? ClaudeCode.model(model.id) }
        }
        if let thinking {
            let effort = ClaudeCode.effort(thinking)
            _ = try await request(["subtype": "apply_flag_settings", "settings": ["effortLevel": .string(effort)]])
            update { $0.thinking = Open(rawValue: effort) }
        }
        if let trimmed {
            _ = try await request(["subtype": "rename_session", "title": .string(trimmed)])
            update { $0.name = trimmed }
        }
    }

    func answer(_ answer: PiAnswerValue, to promptID: String) async throws {
        guard let waiting = permission else { throw PiBridgeError.rejected("no_prompt") }
        let decision = try waiting.permission.decision(answer, to: promptID)
        permission = nil
        try write(["type": "control_response", "response": ["subtype": "success", "request_id": .string(waiting.request), "response": decision]])
        update { session in
            session.question = nil
            session.enter(.thinking, at: .now)
        }
    }

    func end() async throws { close() }
}
#endif

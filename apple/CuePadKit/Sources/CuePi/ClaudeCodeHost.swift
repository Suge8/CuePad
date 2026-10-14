#if os(macOS)
import CueStore
import Darwin
import Foundation

/// CuePad 在后台托管的一个 Claude Code 会话：`claude` 以 stream-json 收发（与 Agent SDK 同一套线协议），没有终端界面，
/// CuePad 掌握它的全部输入输出——发话（带图）、斜杠命令、停止、换模型与强度、改名、作答、结束都能做。
///
/// - 状态来自它的输出：`session_state_changed`（要 `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS`）、模型回答里的工具调用、`can_use_tool`、`result`；
///   它自己也会跑用户装的钩子（`ClaudeCodeRuntime` 按进程认出来直接放行，不重复登记）。
/// - 发话的 `priority`：`next` 在这一轮跑完当前工具后插进去（马上说），`later` 等这一轮做完（等它做完再说）；`now` 会打断在跑的工具，不用。
/// - 退出靠关标准输入（读到 EOF 正常收尾）；空闲满时限、或这个会话在终端里打开了（让出）时也这样退，都不算结束。
@MainActor
final class ClaudeHostedSession: SessionLink {
    let sessionID: String
    let process: Process
    private let stdin: FileHandle
    private let writes = DispatchQueue(label: "cuepi.claude.stdin")
    private weak var bridge: PiBridge?
    private let idleLimit: Duration
    /// 上了桥之后的 id（`initialize` 回来之前为 nil）
    private(set) var id: PiSession.ID?
    private var requests: [String: CheckedContinuation<ClaudeJSON, any Error>] = [:]
    private var permission: (request: String, permission: ClaudePermission)?
    private var commands: Set<String> = []
    private var stopping = false
    /// 输出读完了（进程退出）：之后的请求不再等
    private var finished = false
    private var inputClosed = false
    private var yielding = false
    private var idleTimer: Task<Void, Never>?
    private var subagents: [(id: String, state: PiSubagentState)] = []
    private var contextWindow: Int?
    /// 进程退出时结束（可以被多处等）
    let exited: Task<Void, Never>
    /// 标准错误的末尾（没连上就退出时报给用户）
    private var stderr = Data()

    private static let requestTimeout: Duration = .seconds(30)
    private static let stderrLimit = 4096

    /// 启动进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    init(
        executable: URL, arguments: [String], sessionID: String, directory: URL, environment: [String: String], bridge: PiBridge,
        idleLimit: Duration
    ) throws {
        self.sessionID = sessionID
        self.bridge = bridge
        self.idleLimit = idleLimit
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--permission-prompt-tool", "stdio", "--permission-mode", "default",
        ] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment.merging(["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS": "1"]) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let (gone, finish) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in finish.finish() }
        exited = Self.watch(gone)
        // 进程先退出时写标准输入得 EPIPE，不要 SIGPIPE
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        stdin = input.fileHandleForWriting
        try process.run()
        let lines = ClaudeLines.stream(output.fileHandleForReading)
        let errorLines = ClaudeLines.stream(errors.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { self?.received(line) }
            self?.ended()
        }
        Task { [weak self] in
            for await line in errorLines { self?.stderr.append(line + Data([0x0A])); self?.trimStderr() }
        }
    }

    /// 不在主线程隔离里建：退出时主线程可能被占住，等进程退出的任务不能排在它后面。
    private nonisolated static func watch(_ gone: AsyncStream<Void>) -> Task<Void, Never> { Task { for await _ in gone {} } }

    private func trimStderr() { if stderr.count > Self.stderrLimit { stderr = stderr.suffix(Self.stderrLimit) } }

    var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 握手（`initialize` 拿到可换的模型与命令）并上桥。
    func connect(cwd: URL, sessionFile: URL, launchToken: String?) async throws -> PiSession {
        let info = try await request(["subtype": "initialize"])
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
        let pid = process.processIdentifier
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

    private func received(_ line: Data) {
        guard let message = ClaudeJSON.parse(line) else { return }
        let now = Date.now
        switch message["type"]?.string {
        case "control_response":
            let response = message["response"]
            guard let request = response?["request_id"]?.string, let waiting = requests.removeValue(forKey: request) else { return }
            if response?["subtype"]?.string == "success" {
                waiting.resume(returning: response?["response"] ?? .object([:]))
            } else {
                waiting.resume(throwing: PiBridgeError.rejected(response?["error"]?.string ?? "failed"))
            }
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
                case "text": update { $0.enter(.outputting, at: now) }
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

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。排在已发出的写入之后关，关了的描述符不会再被写（它的号可能已被别的文件复用）。
    func close() {
        idleTimer?.cancel()
        idleTimer = nil
        guard !inputClosed else { return }
        inputClosed = true
        writes.async { [stdin] in try? stdin.close() }
    }

    /// 输出读完了（进程退出）：没答的请求以会话结束收尾，下桥。
    private func ended() {
        finished = true
        idleTimer?.cancel()
        for waiting in requests.values { waiting.resume(throwing: PiBridgeError.sessionEnded) }
        requests = [:]
        if let id { bridge?.detach(id, reason: .closed(reason: "quit")) }
    }

    // MARK: 输入

    private func write(_ message: ClaudeJSON) throws {
        guard !inputClosed, !finished else { throw PiBridgeError.sessionEnded }
        let line = message.data + Data([0x0A])
        let fd = stdin.fileDescriptor
        writes.async {
            line.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return }  // 进程已退出：读端随即结束，等着的请求在那里收尾
                    offset += n
                }
            }
        }
    }

    private func request(_ body: ClaudeJSON) async throws -> ClaudeJSON {
        guard !finished else { throw PiBridgeError.sessionEnded }
        let requestID = UUID().uuidString
        var timeout: Task<Void, Never>?
        defer { timeout?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try write(["type": "control_request", "request_id": .string(requestID), "request": body])
            } catch {
                return continuation.resume(throwing: error)
            }
            requests[requestID] = continuation
            timeout = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.requestTimeout)) != nil else { return }
                self?.requests.removeValue(forKey: requestID)?.resume(throwing: PiBridgeError.ackTimeout)
            }
        }
    }

    private var busy: Bool { id.flatMap { bridge?.session(id: $0) }?.state.isTurnRunning == true }

    private func priority(_ mode: PiQueueMode) -> ClaudeJSON { .string(!busy ? "next" : mode == .steer ? "next" : "later") }

    // MARK: SessionLink

    func send(_ message: PiMessage) async throws -> PiDelivery {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw PiBridgeError.rejected("empty")
        }
        let mode = message.whenBusy ?? .followUp
        let delivered: PiDelivery = busy ? .queued(mode) : .immediate
        var content: [ClaudeJSON] = message.text.isEmpty ? [] : [["type": "text", "text": .string(message.text)]]
        for image in message.images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]])
        }
        try write([
            "type": "user", "message": ["role": "user", "content": .array(content)], "parent_tool_use_id": .null, "session_id": "",
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
            // Claude Code 换模型时先向服务端核对：只有"不支持这个模型"才是模型表里没有，别的（网络、限流、认证）照原话报
            do {
                _ = try await request(["subtype": "set_model", "model": .string(model.id)])
            } catch PiBridgeError.rejected(let reason) {
                let unknown = ["unsupported model", "not found", "unknown model", "invalid model"].contains { reason.lowercased().contains($0) }
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

/// 子进程输出按行（`\n`）切开。不用 `FileHandle.bytes.lines`：它也在 U+2028 等字符处断行，而 JSON 字符串里可以原样出现它们。
enum ClaudeLines {
    static func stream(_ handle: FileHandle) -> AsyncStream<Data> {
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        let fd = handle.fileDescriptor
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var pending = Data()
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    if !line.isEmpty { continuation.yield(Data(line)) }
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            continuation.finish()
            try? handle.close()
        }
        return lines
    }
}
#endif

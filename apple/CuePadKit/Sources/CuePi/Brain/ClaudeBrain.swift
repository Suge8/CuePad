#if os(macOS)
import CueStore
import Foundation

/// Claude Code 当大脑：`claude -p` 的流式输入输出（`--input-format/--output-format stream-json`），标准输入一直开着做多轮。
/// - 不落会话（`--no-session-persistence`），不进 `claude --resume` 的列表；
/// - 系统提示整份替换（`--system-prompt-file`）；不读 CLAUDE.md 与自动记忆（`CLAUDE_CODE_DISABLE_CLAUDE_MDS`、
///   `CLAUDE_CODE_DISABLE_AUTO_MEMORY`），不跑用户的钩子（`--settings` 里的 `disableAllHooks`），不加载 skill 与斜杠命令；
/// - 原生工具只有 `Read,Grep,Glob`，MCP 只有 CuePad 的（`--strict-mcp-config`）；这些工具预先放行，其余需要批准的一律拒绝
///   （`--permission-prompts none`），不会停下来等人；
/// - 正忙时写进标准输入的话由 Claude Code 并进当前这一轮；
/// - 思考强度：`--effort` 只有 low 到 max，off、minimal 夹到 low（Claude Code 没有关掉思考的档位）；
/// - 一轮从 `system/init` 到 `result`；停下这一轮走控制请求 `interrupt`。
actor ClaudeBrain: CueBrain {
    nonisolated let events: AsyncStream<CueBrainEvent>
    private let emit: AsyncStream<CueBrainEvent>.Continuation
    private var process: BrainProcess?
    private var runner: Task<Void, Never>?
    private var directory: URL?
    private var pending = PendingReplies()
    private var nextID = 0
    private var turn: Turn?
    private struct Turn {
        var used: Int?
        var aborted = false
    }

    init() {
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start(_ config: CueBrainConfig) async throws {
        guard process == nil else { return }
        let directory = try makeBrainDirectory()
        self.directory = directory
        let prompt = directory.appending(path: "system-prompt.md")
        try config.systemPrompt.write(to: prompt, atomically: true, encoding: .utf8)
        let mcp = ["mcpServers": ["cuepad": ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]]]

        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence",
            "--system-prompt-file", prompt.path, "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob,mcp__cuepad__*",
            "--permission-prompts", "none", "--strict-mcp-config", "--mcp-config", jsonString(mcp),
            "--settings", #"{"disableAllHooks":true}"#, "--disable-slash-commands",
        ]
        if let model = config.model { arguments += ["--model", model] }
        if let effort = config.effort { arguments += ["--effort", Self.effort(effort)] }
        let environment = brainEnvironment(config, ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
        let process = try BrainProcess(executable: config.executable, arguments: arguments, directory: config.workingDirectory, environment: environment)
        self.process = process
        runner = Task { await self.run(process) }
    }

    func send(_ text: String) async throws {
        guard let process else { throw CueBrainError.notRunning }
        try process.write(["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull()])
    }

    func abort() async throws {
        guard turn != nil else { return }
        turn?.aborted = true
        _ = try await control(["subtype": "interrupt"])
    }

    func stop() async {
        await process?.stop()
        await runner?.value
        process = nil
    }

    static func effort(_ level: PiThinkingLevel) -> String {
        switch level {
        case .off, .minimal: "low"
        case .low, .medium, .high, .xhigh, .max: level.rawValue
        }
    }

    private func run(_ process: BrainProcess) async {
        let reason = await process.pump { self.receive($0) }
        pending.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        emit.yield(.exited(reason))
        emit.finish()
    }

    private func control(_ request: [String: Any]) async throws -> [String: Any] {
        guard let process else { throw CueBrainError.notRunning }
        nextID += 1
        let id = "cue-\(nextID)"
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending.add(id, continuation)
            do { try process.write(["type": "control_request", "request_id": id, "request": request]) } catch { pending.fail(id, error) }
        }
        guard reply["subtype"] as? String == "success" else { throw CueBrainError.rejected(reply["error"] as? String ?? "未知错误") }
        return reply
    }

    private func receive(_ line: Data) {
        guard let event = jsonObject(line), let type = event["type"] as? String else { return }
        switch type {
        case "control_response":
            if let response = event["response"] as? [String: Any], let id = response["request_id"] as? String { _ = pending.resolve(id, response) }
        case "control_request":
            // Claude Code 问的事（批准工具……）一律不答应，回错误免得这一轮卡住
            guard let id = event["request_id"] as? String else { return }
            try? process?.write(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "CuePad does not handle this request"]])
        case "system":
            guard event["subtype"] as? String == "init", turn == nil else { return }
            turn = Turn()
            emit.yield(.turnStarted)
        case "assistant":
            // 子代理的消息带 parent_tool_use_id；用量为 0 的是 Claude Code 自己合成的（报错等），不是模型请求
            guard event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil,
                  let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] else { return }
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            guard used > 0, used != turn?.used else { return }
            turn?.used = used
            emit.yield(.context(used: used, window: nil))
        case "result":
            finish(event)
        default:
            break
        }
    }

    private func finish(_ result: [String: Any]) {
        let finished = turn ?? Turn()
        turn = nil
        let windows = (result["modelUsage"] as? [String: [String: Any]])?.values.compactMap { $0["contextWindow"] as? Int } ?? []
        if let used = finished.used, let window = windows.max() { emit.yield(.context(used: used, window: window)) }
        let text = (result["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result["is_error"] as? Bool == true {
            if !finished.aborted { emit.yield(.failed(text.isEmpty ? (result["subtype"] as? String ?? "未知错误") : text)) }
        } else if !finished.aborted, !text.isEmpty {
            emit.yield(.reply(text))
        }
        emit.yield(.turnFinished)
    }
}
#endif

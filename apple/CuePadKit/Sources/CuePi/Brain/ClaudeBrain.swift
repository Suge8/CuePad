#if os(macOS)
import CueStore
import Foundation

/// Claude Code 当大脑：`claude -p` 的流式输入输出，经接入里的 `ClaudeStream`，标准输入一直开着做多轮。
/// - 不落会话（`--no-session-persistence`），不进 `claude --resume` 的列表；
/// - 系统提示整份替换（`--system-prompt-file`）；不读 CLAUDE.md 与自动记忆（`CLAUDE_CODE_DISABLE_CLAUDE_MDS`、
///   `CLAUDE_CODE_DISABLE_AUTO_MEMORY`），不跑用户的钩子（`--settings` 里的 `disableAllHooks`，也就不会报给 CuePad 成一个会话），
///   不加载 skill 与斜杠命令；
/// - 原生工具只有 `Read,Grep,Glob`，MCP 只有 CuePad 的（`--strict-mcp-config`）；这些工具预先放行，其余需要批准的一律拒绝
///   （`--permission-prompts none`），不会停下来等人；
/// - 正忙时写进标准输入的话由 Claude Code 并进当前这一轮；
/// - 思考强度按 Claude Code 的档位夹取（`ClaudeCode.effort`）；
/// - 一轮从 `system/init` 到 `result`；停下这一轮走控制请求 `interrupt`。
@MainActor
final class ClaudeBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var stream: ClaudeStream?
    private var turn: Turn?
    private struct Turn {
        var used: Int?
        var aborted = false
    }

    func start(_ config: CueBrainConfig) async throws {
        do {
            let directory = try session.makeDirectory()
            let prompt = directory.appending(path: "system-prompt.md")
            try config.systemPrompt.write(to: prompt, atomically: true, encoding: .utf8)
            let mcp = ["mcpServers": ["cuepad": ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]]]
            var arguments = [
                "-p", "--no-session-persistence", "--system-prompt-file", prompt.path, "--tools", "Read,Grep,Glob",
                "--allowedTools", "Read,Grep,Glob,mcp__cuepad__*", "--permission-prompts", "none", "--strict-mcp-config",
                "--mcp-config", jsonString(mcp), "--settings", #"{"disableAllHooks":true}"#, "--disable-slash-commands",
            ]
            if let model = config.model { arguments += ["--model", model] }
            if let effort = config.effort { arguments += ["--effort", ClaudeCode.effort(effort)] }
            let environment = BrainSession.environment(config, ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
            let stream = try ClaudeStream(
                executable: config.executable, arguments: arguments, directory: config.workingDirectory, environment: environment)
            self.stream = stream
            stream.onMessage = { [weak self] in self?.received($0) }
            let process = stream.process
            stream.onClose = { [weak self] in
                Task { self?.session.exited(await process.exited()) }
            }
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    func send(_ text: String) async throws {
        guard let stream else { throw CueBrainError.notRunning }
        try stream.write(["type": "user", "message": ["role": "user", "content": .string(text)], "parent_tool_use_id": .null])
    }

    func abort() async throws {
        guard let stream, turn != nil else { return }
        turn?.aborted = true
        _ = try await stream.request(["subtype": "interrupt"])
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = stream?.process
        return { await process?.stop() }
    }

    private func received(_ event: ClaudeJSON) {
        switch event["type"]?.string {
        case "control_request":
            // Claude Code 问的事（批准工具……）一律不答应，回错误免得这一轮卡住
            guard let id = event["request_id"]?.string else { return }
            try? stream?.write(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": "CuePad does not handle this request"]])
        case "system":
            guard event["subtype"]?.string == "init", turn == nil else { return }
            turn = Turn()
            session.emit(.turnStarted)
        case "assistant":
            // 子代理的消息带 parent_tool_use_id；用量为 0 的是 Claude Code 自己合成的（报错等），不是模型请求
            guard event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] == .null,
                  let usage = event["message"]?["usage"] else { return }
            let used = Int(["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0]?.number }.reduce(0, +))
            guard used > 0, used != turn?.used else { return }
            turn?.used = used
            session.emit(.context(used: used, window: nil))
        case "result":
            finish(event)
        default:
            break
        }
    }

    private func finish(_ result: ClaudeJSON) {
        let finished = turn ?? Turn()
        turn = nil
        let windows = (result["modelUsage"]?.object ?? [:]).values.compactMap { $0["contextWindow"]?.number }
        if let used = finished.used, let window = windows.max() { session.emit(.context(used: used, window: Int(window))) }
        let text = result["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result["is_error"]?.bool == true {
            if !finished.aborted { session.emit(.failed(text.isEmpty ? (result["subtype"]?.string ?? "未知错误") : text)) }
        } else if !finished.aborted, !text.isEmpty {
            session.emit(.reply(text))
        }
        session.emit(.turnFinished)
    }
}
#endif

#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Claude Code 当大脑：`claude -p` 的流式输入输出，经接入里的 `ClaudeStream`，标准输入一直开着做多轮。启动参数（见 `start`）保证：
/// 不进 `claude --resume` 的列表；系统提示整份替换，不读 CLAUDE.md、自动记忆、skill 与斜杠命令；不跑用户的钩子（也就不会报给 CuePad
/// 成一个会话）；工具只有只读的三样与 CuePad 的 MCP，其余需要批准的一律拒绝，不会停下来等人。
/// - 正忙时写进标准输入的话由 Claude Code 并进当前这一轮；
/// - 思考强度按 Claude Code 的档位夹取（`ClaudeCode.effort`）；就地换模型与强度走控制请求（与托管会话同一份，见 `ClaudeStream`）；
/// - 一轮从开始请求模型（`ClaudeStream.requestsModel`）到 `result`；停下这一轮走控制请求 `interrupt`；
/// - 正在说的话用 `ClaudeStream` 累积好的（`onDraft`）；被停下的一轮在 `turnFinished` 前清掉（它的 `result` 不一定标出错）。
@MainActor
final class ClaudeBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var stream: ClaudeStream?
    /// Claude 的模型都能看图
    let seesImages = true
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
            let mcp = ["mcpServers": [CueMCPServer.name: ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]]]
            var arguments = [
                "-p", "--no-session-persistence", "--system-prompt-file", prompt.path, "--tools", "Read,Grep,Glob",
                "--allowedTools", "Read,Grep,Glob,\(CueMCPServer.toolPrefix)*", "--permission-prompts", "none", "--strict-mcp-config",
                "--mcp-config", jsonString(mcp), "--settings", #"{"disableAllHooks":true}"#, "--disable-slash-commands",
            ]
            if let model = config.model { arguments += ["--model", model] }
            if let effort = config.effort { arguments += ["--effort", ClaudeCode.effort(effort)] }
            let environment = BrainSession.environment(config, ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"])
            let stream = try await ClaudeStream(
                executable: config.executable, arguments: arguments, directory: config.workingDirectory, environment: environment)
            self.stream = stream
            stream.onMessage = { [weak self] in self?.received($0) }
            stream.onDraft = { [weak self] in self?.session.emit(.speaking($0)) }
            let process = stream.process
            stream.onClose = { [weak self] in
                Task { self?.session.exited(await process.exited()) }
            }
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let stream else { throw CueBrainError.notRunning }
        try stream.write(["type": "user", "message": ["role": "user", "content": ClaudeStream.content(text: text, images: images)], "parent_tool_use_id": .null])
    }

    func configure(model: String?, effort: PiThinkingLevel?) async throws {
        guard let stream else { throw CueBrainError.notRunning }
        if let model { try await stream.setModel(model) }
        if let effort { try await stream.setEffort(effort) }
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

    private func received(_ event: JSONValue) {
        switch event["type"]?.string {
        case "control_request":
            // Claude Code 问的事（批准工具……）一律不答应，回错误免得这一轮卡住
            guard let id = event["request_id"]?.string else { return }
            try? stream?.write(["type": "control_response", "response": ["subtype": "error", "request_id": .string(id), "error": "CuePad does not handle this request"]])
        case "system":
            guard ClaudeStream.requestsModel(event), turn == nil else { return }
            turn = Turn()
            session.emit(.turnStarted)
        case "assistant":
            // 子代理的消息带 parent_tool_use_id；用量为 0 的是 Claude Code 自己合成的（报错等），不是模型请求
            guard event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] == .null else { return }
            for block in event["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                let arguments = String(decoding: (block["input"] ?? [:]).data, as: UTF8.self)
                session.emit(.tool(id: block["id"]?.string ?? "", name: brainToolName(block["name"]?.string ?? "?"), arguments: arguments))
            }
            guard let usage = event["message"]?["usage"] else { return }
            let used = Int(["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0]?.number }.reduce(0, +))
            guard used > 0, used != turn?.used else { return }
            turn?.used = used
            session.emit(.context(used: used, window: nil))
        case "user":
            // 工具的结果回来了
            guard turn != nil, event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] == .null else { return }
            for block in event["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                session.emit(.toolDone(id: block["tool_use_id"]?.string ?? "", result: brainText(block["content"]), failed: block["is_error"]?.bool == true))
            }
        case "result":
            finish(event)
        default:
            break
        }
    }

    private func finish(_ result: JSONValue) {
        let finished = turn ?? Turn()
        turn = nil
        let windows = (result["modelUsage"]?.object ?? [:]).values.compactMap { $0["contextWindow"]?.number }
        if let used = finished.used, let window = windows.max() { session.emit(.context(used: used, window: Int(window))) }
        if finished.aborted {
            session.emit(.speaking(nil))
        } else if result["is_error"]?.bool == true {
            let text = result["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            session.emit(.failed(text.isEmpty ? (result["subtype"]?.string ?? "未知错误") : text))
        }
        session.emit(.turnFinished)
    }
}
#endif

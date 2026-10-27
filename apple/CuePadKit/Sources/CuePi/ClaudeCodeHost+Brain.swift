#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 当 Cue 的大脑开（`init()` 再 `start`）：不挂桥、不进会话列表，一轮的状态与托管会话同一套，经 `events` 交出。
/// 启动参数（见 `start`）保证：不落会话（不进 `claude --resume` 的列表）；系统提示整份替换，不读 CLAUDE.md、自动记忆与 skill；
/// 不跑用户的钩子（也就不会报给 CuePad 成一个会话）；工具只有只读的三样与 CuePad 的 MCP，其余需要批准的一律拒绝（`--permission-prompts none`），
/// 不会停下来等人。斜杠命令开着，只为开新会话的 `/clear`（见下）。
/// - 正忙时说的话并进当前这一轮（不先停下，与托管会话的发话不同）；他的话以 `/` 开头时前面垫一个空格，不被当成命令；
/// - 开新会话是写一句 `/clear`：Claude Code 清掉对话（进程、MCP 连接、模型与强度都留着），回一条不调模型的 `result`，不报成一轮；
/// - 提示缓存留 1 小时（`ENABLE_PROMPT_CACHING_1H`：订阅登录多数时候本来就是，API 密钥与超额时默认 5 分钟）；
/// - 思考强度按 Claude Code 的档位夹取（`ClaudeCode.effort`）；就地换模型与强度走控制请求（`ClaudeStream`）。
extension ClaudeHostedSession: HostedSession {
    var events: AsyncStream<TurnEvent> { brain?.events ?? AsyncStream { $0.finish() } }
    /// Claude 的模型都能看图
    var seesImages: Bool { true }

    func start(_ config: CueBrainConfig) async throws {
        guard let brain else { throw HostedSessionError.notRunning }
        do {
            let directory = try brain.makeDirectory()
            let prompt = directory.appending(path: "system-prompt.md")
            try config.systemPrompt.write(to: prompt, atomically: true, encoding: .utf8)
            let mcp = ["mcpServers": [CueMCPServer.name: ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]]]
            var arguments = [
                "-p", "--no-session-persistence", "--system-prompt-file", prompt.path, "--tools", "Read,Grep,Glob",
                "--allowedTools", "Read,Grep,Glob,\(CueMCPServer.toolPrefix(on: .claudeCode))*", "--permission-prompts", "none", "--strict-mcp-config",
                "--mcp-config", jsonString(mcp), "--settings", #"{"disableAllHooks":true}"#,
            ]
            if let model = config.model { arguments += ["--model", model] }
            if let effort = config.effort { arguments += ["--effort", ClaudeCode.effort(effort)] }
            let environment = BrainSession.environment(config, [
                "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_PROMPT_CACHING_1H": "1",
            ])
            _ = try await launch(config.executable, arguments, directory: config.workingDirectory, environment: environment)
        } catch {
            await brain.abandon(stop())
            throw error
        }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        let text = text.hasPrefix("/") ? " " + text : text
        try await say(Self.userMessage(ClaudeStream.content(text: text, images: images)), interrupting: false)
    }

    func newSession() async throws {
        let stream = try live
        try await withCheckedThrowingContinuation { continuation in
            clearing = continuation
            do {
                try stream.write(Self.userMessage("/clear"))
            } catch {
                clearing = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func configure(model: String?, effort: PiThinkingLevel?) async throws {
        let stream = try live
        if let model { try await stream.setModel(model) }
        if let effort { try await stream.setEffort(effort) }
    }

    func abort() async throws {
        try await interrupt(restarting: false)
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = stream?.process
        return { await process?.stop() }
    }
}
#endif

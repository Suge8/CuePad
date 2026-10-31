#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 当 Cue 的大脑开（`init()` 再 `start`）：不挂桥、不进会话列表，一轮的状态与托管会话同一套，经 `events` 交出。
/// 启动参数（见 `start`）保证：不落会话（不进 `claude --resume` 的列表）；系统提示整份替换，不读 CLAUDE.md、自动记忆与 skill；
/// 不跑用户的钩子（也就不会报给 CuePad 成一个会话）；工具只有只读的三样与 CuePad 的 MCP，其余需要批准的一律拒绝（`--permission-prompts none`），
/// 不会停下来等人。斜杠命令开着，只为开新会话的 `/clear`（见下）。
/// - 正忙时说的话并进当前这一轮（不先停下，与托管会话的发话不同）；他的话以 `/` 开头时前面垫一个空格，不被当成命令；
/// - 起好要等 CuePad 的 MCP 服务连上（`toolsConnected`）；工具搜索关掉（`ENABLE_TOOL_SEARCH=false`）：缺省的 auto 在 CuePad 的工具说明
///   长到一定程度后，模型的第一下调用改用不带前缀的名字（`task`），被拒成"No such tool"（2.1.312 实测，同一份工具清单显式开、关都不会）；
///   Cue 只有四个工具，一直全量给模型；
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
            let environment = config.launchEnvironment(adding: [
                "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_PROMPT_CACHING_1H": "1",
                "ENABLE_TOOL_SEARCH": "false",
            ])
            _ = try await launch(config.executable, arguments, directory: config.workingDirectory, environment: environment)
            try await toolsConnected()
        } catch {
            await brain.abandon(stop())
            throw error
        }
    }

    /// 等 CuePad 的 MCP 服务连上再算起好：Claude Code 起进程后在后台连 MCP（2.1.312 实测握手后约 0.2 秒还是 pending），
    /// 这时交第一句话，模型那一轮的工具清单里没有 CuePad 的工具，第一下调用必定是"No such tool"。Claude Code 不推送连上的事件，
    /// 只能问 `mcp_status`；连不上（failed）或到起进程的时限（同 OpenCode 的大脑）还没连上就抛，由管理器按起不来重试。
    private func toolsConnected() async throws {
        let stream = try live, deadline = ContinuousClock.now + AgentTimeouts.launch
        while true {
            let servers = try await stream.request(["subtype": "mcp_status"])["mcpServers"]?.array ?? []
            let status = servers.first { $0["name"]?.string == CueMCPServer.name }?["status"]?.string
            if status == "connected" { return }
            guard status == "pending" || status == nil, ContinuousClock.now < deadline else {
                throw HostedSessionError.rejected(String(localized: "CuePad 的工具服务没连上（\(status ?? "没有登记")）"))
            }
            try await Task.sleep(for: Self.toolsPoll)
        }
    }

    private static let toolsPoll: Duration = .milliseconds(100)

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

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = stream?.process
        return { await process?.stop() }
    }
}
#endif

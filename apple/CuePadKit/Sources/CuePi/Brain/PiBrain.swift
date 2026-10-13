#if os(macOS)
import CueStore
import Foundation

/// Pi 当大脑：RPC 模式（`pi --mode rpc`，协议见 Pi 的 docs/rpc.md）。
/// - 不落会话（`--no-session`）；不发现扩展（`-ne`，CuePad 的桥扩展也不加载，所以它不在 Agent 会话列表里），
///   只加载内置的 MCP 支持与一个临时扩展，后者用 `pi.registerMcpServer` 登记 CuePad 的 MCP 服务（工具直接声明给模型）；
///   不读工作目录里的项目文件（`-na`：项目的 `.pi/` 设置、扩展与 MCP 配置都不信任），也不加载 skill、上下文文件、提示词模板；
/// - 工具只有 `read,grep,find,ls` 与 `mcp__cuepad__*`：清单里有 `mcp__` 开头的项时，其余 MCP 服务的工具都不给；
/// - 思考强度原样交给 `--thinking`（Pi 自己按模型支持的档位夹取）；
/// - 发话一律带 `streamingBehavior: steer`：正忙时 Pi 在当前回合的工具调用做完后、下一次请求模型前把它交给模型，空闲时照常开始一轮；
/// - 一轮从第一个 `agent_start` 到 `agent_settled`（重试、压缩、插话都在其中）。
actor PiBrain: CueBrain {
    nonisolated let events: AsyncStream<CueBrainEvent>
    private let emit: AsyncStream<CueBrainEvent>.Continuation
    private var process: BrainProcess?
    private var runner: Task<Void, Never>?
    private var directory: URL?
    private var pending = PendingReplies()
    private var nextID = 0
    private var window: Int?
    /// 这一轮里的状况（`agent_start` 到 `agent_settled`）
    private var turn: Turn?
    private struct Turn {
        var reply: String?
        var error: String?
    }

    init() {
        (events, emit) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start(_ config: CueBrainConfig) async throws {
        guard process == nil else { return }
        do {
            try await launch(config)
        } catch {
            // 握手失败：调用方拿不到这个大脑，起了的进程与临时文件这里收拾
            await stop()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    private func launch(_ config: CueBrainConfig) async throws {
        let directory = try makeBrainDirectory()
        self.directory = directory
        let prompt = directory.appending(path: "system-prompt.md")
        try config.systemPrompt.write(to: prompt, atomically: true, encoding: .utf8)
        let mcpExtension = directory.appending(path: "cuepad-mcp.ts")
        let server: [String: Any] = [
            "command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment, "exposure": "direct",
        ]
        try "export default function (pi: any) { pi.registerMcpServer(\"cuepad\", \(jsonString(server))); }\n"
            .write(to: mcpExtension, atomically: true, encoding: .utf8)

        var arguments = [
            "--mode", "rpc", "--no-session", "--offline", "-ne", "-na", "-e", "builtin:mcp", "-e", mcpExtension.path,
            "-ns", "-nc", "-np", "--no-themes", "--system-prompt", prompt.path, "--tools", "read,grep,find,ls,mcp__cuepad__*",
        ]
        if let model = config.model { arguments += ["--model", model] }
        if let effort = config.effort { arguments += ["--thinking", effort.rawValue] }
        let process = try BrainProcess(
            executable: config.executable, arguments: arguments, directory: config.workingDirectory, environment: brainEnvironment(config))
        self.process = process
        runner = Task { await self.run(process) }

        let state = try await request(["type": "get_state"])
        window = ((state["data"] as? [String: Any])?["model"] as? [String: Any])?["contextWindow"] as? Int
    }

    func send(_ text: String) async throws {
        _ = try await request(["type": "prompt", "message": text, "streamingBehavior": "steer"])
    }

    func abort() async throws {
        _ = try await request(["type": "abort"])
    }

    func stop() async {
        await process?.stop()
        await runner?.value
        process = nil
    }

    private func run(_ process: BrainProcess) async {
        let reason = await process.pump { self.receive($0) }
        pending.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        emit.yield(.exited(reason))
        emit.finish()
    }

    /// 发一条命令、等它的回应；回应 `success: false` 抛 `rejected`。
    private func request(_ command: [String: Any]) async throws -> [String: Any] {
        guard let process else { throw CueBrainError.notRunning }
        nextID += 1
        let id = "cue-\(nextID)"
        var command = command
        command["id"] = id
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending.add(id, continuation)
            do { try process.write(command) } catch { pending.fail(id, error) }
        }
        guard reply["success"] as? Bool == true else { throw CueBrainError.rejected(reply["error"] as? String ?? "未知错误") }
        return reply
    }

    private func receive(_ line: Data) {
        guard let event = jsonObject(line), let type = event["type"] as? String else { return }
        switch type {
        case "response":
            if let id = event["id"] as? String { _ = pending.resolve(id, event) }
        case "agent_start":
            guard turn == nil else { return }
            turn = Turn()
            emit.yield(.turnStarted)
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return }
            assistantMessage(message)
        case "agent_settled":
            guard let finished = turn else { return }
            turn = nil
            if event["aborted"] as? Bool != true, let reply = finished.reply { emit.yield(.reply(reply)) }
            if let error = finished.error { emit.yield(.failed(error)) }
            emit.yield(.turnFinished)
        default:
            break
        }
    }

    private func assistantMessage(_ message: [String: Any]) {
        if let usage = message["usage"] as? [String: Any] {
            let used = ["input", "cacheRead", "cacheWrite"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            if used > 0 { emit.yield(.context(used: used, window: window)) }
        }
        let text = (message["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { turn?.reply = text }
        // 被 abort 停下的是 "aborted"，不算出错；之后成功的请求（重试）清掉前面的错
        turn?.error = message["stopReason"] as? String == "error" ? (message["errorMessage"] as? String ?? "未知错误") : nil
    }
}
#endif

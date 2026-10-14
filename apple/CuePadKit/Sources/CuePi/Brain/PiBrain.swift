#if os(macOS)
import CueStore
import Foundation

/// Pi 当大脑：RPC 模式（`pi --mode rpc`，协议见 Pi 的 docs/rpc.md），一行一条 JSON（`ChildProcess`）。
/// - 不落会话（`--no-session`）；不发现扩展（`-ne`，CuePad 的桥扩展也不加载，所以它不在 Agent 会话列表里），
///   只加载内置的 MCP 支持与一个临时扩展，后者用 `pi.registerMcpServer` 登记 CuePad 的 MCP 服务（工具直接声明给模型）；
///   不读工作目录里的项目文件（`-na`：项目的 `.pi/` 设置、扩展与 MCP 配置都不信任），也不加载 skill、上下文文件、提示词模板；
/// - 工具只有 `read,grep,find,ls` 与 `mcp__cuepad__*`：清单里有 `mcp__` 开头的项时，其余 MCP 服务的工具都不给；
/// - 思考强度原样交给 `--thinking`（Pi 自己按模型支持的档位夹取）；
/// - 发话一律带 `streamingBehavior: steer`：正忙时 Pi 在当前回合的工具调用做完后、下一次请求模型前把它交给模型，空闲时照常开始一轮；
/// - 一轮从第一个 `agent_start` 到 `agent_settled`（重试、压缩、插话都在其中）。
@MainActor
final class PiBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var process: ChildProcess?
    /// 等回应的命令
    private let replies = PendingReplies<String, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: CueBrainError.rejected("没有及时回应"))
    private var nextID = 0
    private var window: Int?
    /// 这一轮里的状况（`agent_start` 到 `agent_settled`）
    private var turn: Turn?
    private struct Turn {
        var reply: String?
        var error: String?
    }

    func start(_ config: CueBrainConfig) async throws {
        do {
            let directory = try session.makeDirectory()
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
            let process = try ChildProcess(
                config.executable, arguments, directory: config.workingDirectory, environment: BrainSession.environment(config),
                placement: .group, input: .pipe, output: .lines)
            self.process = process
            Task {
                for await line in process.output { received(line) }
                ended(await process.exited())
            }
            let state = try await command(["type": "get_state"])
            window = state["data"]?["model"]?["contextWindow"]?.int
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    func send(_ text: String) async throws {
        _ = try await command(["type": "prompt", "message": .string(text), "streamingBehavior": "steer"])
    }

    func abort() async throws {
        _ = try await command(["type": "abort"])
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let process = process
        return { await process?.stop() }
    }

    /// 发一条命令、等它的回应；回应 `success: false` 抛 `rejected`。
    private func command(_ command: [String: JSONValue]) async throws -> JSONValue {
        guard let process else { throw CueBrainError.notRunning }
        nextID += 1
        let id = "cue-\(nextID)"
        let reply = try await replies.request(id) { process.write(JSONValue.object(command.merging(["id": .string(id)]) { $1 }).data) }
        guard reply["success"]?.bool == true else { throw CueBrainError.rejected(reply["error"]?.string ?? "未知错误") }
        return reply
    }

    /// 进程退出：等着的命令以 `notRunning` 失败，报退出。
    private func ended(_ reason: String?) {
        replies.closeAll(CueBrainError.notRunning)
        session.exited(reason)
    }

    private func received(_ line: Data) {
        guard let event = JSONValue.parse(line), let type = event["type"]?.string else { return }
        switch type {
        case "response":
            if let id = event["id"]?.string { replies.resolve(id, with: .success(event)) }
        case "agent_start":
            guard turn == nil else { return }
            turn = Turn()
            session.emit(.turnStarted)
        case "message_end":
            guard let message = event["message"], message["role"]?.string == "assistant" else { return }
            assistantMessage(message)
        case "agent_settled":
            guard let finished = turn else { return }
            turn = nil
            if event["aborted"]?.bool != true, let reply = finished.reply { session.emit(.reply(reply)) }
            if let error = finished.error { session.emit(.failed(error)) }
            session.emit(.turnFinished)
        default:
            break
        }
    }

    private func assistantMessage(_ message: JSONValue) {
        if let usage = message["usage"] {
            let used = ["input", "cacheRead", "cacheWrite"].reduce(0) { $0 + (usage[$1]?.int ?? 0) }
            if used > 0 { session.emit(.context(used: used, window: window)) }
        }
        let text = (message["content"]?.array ?? []).filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { turn?.reply = text }
        // 被 abort 停下的是 "aborted"，不算出错；之后成功的请求（重试）清掉前面的错
        turn?.error = message["stopReason"]?.string == "error" ? (message["errorMessage"]?.string ?? "未知错误") : nil
    }
}
#endif

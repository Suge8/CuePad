#if os(macOS)
import CueStore
import Foundation

/// Pi 当大脑：RPC 模式（`pi --mode rpc`，协议见 Pi 的 docs/rpc.md），一行一条 JSON（`ChildProcess`）。
/// - 不落会话（`--no-session`）；不发现扩展（`-ne`，CuePad 的桥扩展也不加载，所以它不在 Agent 会话列表里），
///   只加载内置的 MCP 支持与一个临时扩展，后者用 `pi.registerMcpServer` 登记 CuePad 的 MCP 服务（工具直接声明给模型）；
///   不读工作目录里的项目文件（`-na`：项目的 `.pi/` 设置、扩展与 MCP 配置都不信任），也不加载 skill、上下文文件、提示词模板；
/// - 工具只有 `read,grep,find,ls` 与 `mcp__cuepad__*`：清单里有 `mcp__` 开头的项时，其余 MCP 服务的工具都不给；
/// - 图随 `prompt` 的 `images` 交；模型能不能看图看 `get_state` 里模型的 `input`；
/// - 思考强度原样交给 `--thinking`（Pi 自己按模型支持的档位夹取）；就地换走 `set_model`（`提供方/模型` 拆开）再 `set_thinking_level`
///   （换模型时 Pi 会按新模型重取强度，所以强度在后）；都只改这个进程，不写 Pi 的设置；
/// - 发话一律带 `streamingBehavior: steer`：正忙时 Pi 在当前回合的工具调用做完后、下一次请求模型前把它交给模型，空闲时照常开始一轮；
/// - 一轮从第一个 `agent_start` 到 `agent_settled`（重试、压缩、插话都在其中）；
/// - 正在说的话（拼法见 `DraftParts`）：段号是 `contentIndex`，`message_update` 的 `text_delta` 追加（RPC 只发增量，见 Pi 的 docs/json.md
///   「Reconstruct streaming messages」），`text_end` 与 `message_end` 给定稿；开出工具调用、停下或出错后这条不再算。
@MainActor
final class PiBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var process: ChildProcess?
    /// 等回应的命令
    private let replies = PendingReplies<String, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: CueBrainError.rejected("没有及时回应"))
    private var nextID = 0
    private var window: Int?
    private(set) var seesImages = false
    /// 这一轮里的状况（`agent_start` 到 `agent_settled`）
    private var turn: Turn?
    private struct Turn {
        var error: String?
    }
    /// 正在说的这条助手消息（段号是 `contentIndex`）；开出工具调用、停下或出错后为 nil，直到下一条消息
    private var speech: DraftParts?

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
            adopt(state["data"]?["model"])
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        let images = images.map { ["type": "image", "data": .string($0.data.base64EncodedString()), "mimeType": .string($0.mimeType)] as JSONValue }
        _ = try await command(["type": "prompt", "message": .string(text), "images": .array(images), "streamingBehavior": "steer"])
    }

    func configure(model: String?, effort: PiThinkingLevel?) async throws {
        if let model {
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CueBrainError.rejected("Pi 的模型要写成 提供方/模型：\(model)") }
            adopt(try await command(["type": "set_model", "provider": .string(parts[0]), "modelId": .string(parts[1])])["data"])
        }
        if let effort { _ = try await command(["type": "set_thinking_level", "level": .string(effort.rawValue)]) }
    }

    /// 在用的模型（Pi 的 Model 对象）：上下文窗口与能不能看图。
    private func adopt(_ model: JSONValue?) {
        window = model?["contextWindow"]?.int
        seesImages = model?["input"]?.array?.contains("image") == true
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
        // 嵌套的调用（工具里再调工具）带 parentToolCallId，不报
        case "tool_execution_start" where event["parentToolCallId"] == nil:
            guard turn != nil, let id = event["toolCallId"]?.string, let name = event["toolName"]?.string else { return }
            session.emit(.tool(id: id, name: brainToolName(name), arguments: String(decoding: (event["args"] ?? [:]).data, as: UTF8.self)))
        case "tool_execution_end" where event["parentToolCallId"] == nil:
            guard turn != nil, let id = event["toolCallId"]?.string else { return }
            session.emit(.toolDone(id: id, result: brainText(event["result"]?["content"]), failed: event["isError"]?.bool == true))
        case "message_start":
            guard event["message"]?["role"]?.string == "assistant" else { return }
            speech = DraftParts()
            speak()
        case "message_update":
            streamed(event["assistantMessageEvent"] ?? [:])
        case "message_end":
            guard let message = event["message"], message["role"]?.string == "assistant" else { return }
            assistantMessage(message)
        case "agent_settled":
            guard let finished = turn else { return }
            turn = nil
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
        let stop = message["stopReason"]?.string
        // 被 abort 停下的是 "aborted"，不算出错；之后成功的请求（重试）清掉前面的错
        turn?.error = stop == "error" ? (message["errorMessage"]?.string ?? "未知错误") : nil
        if stop == "error" || stop == "aborted" { speech = nil }
        for (index, block) in (message["content"]?.array ?? []).enumerated() where block["type"]?.string == "text" {
            speech?.finish(index, with: block["text"]?.string ?? "")
        }
        speak()
    }

    private func streamed(_ update: JSONValue) {
        guard let index = update["contentIndex"]?.int else { return }
        switch update["type"]?.string {
        case "text_delta": speech?.append(update["delta"]?.string ?? "", to: index)
        case "text_end": if let text = update["content"]?.string { speech?.finish(index, with: text) }
        case "toolcall_start": speech = nil
        default: return
        }
        speak()
    }

    private func speak() { session.emit(.speaking(speech?.draft)) }
}
#endif

#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Pi 当大脑：RPC 模式（`pi --mode rpc`，协议见 Pi 的 docs/rpc.md），一行一条 JSON（`ChildProcess`）。
/// - 不落会话（`--no-session`）；不发现扩展（`-ne`，CuePad 的桥扩展也不加载，所以它不在 Agent 会话列表里），
///   只加载随包的 cue-tools.ts：它当 CuePad 的 MCP 服务的客户端，把工具照原名（task、tell、memory）登记给模型，不走 Pi 内置 MCP 的
///   `mcp__cuepad__` 命名（见它的头注释）；服务的命令行经环境变量 `CUEPAD_CUE_MCP` 交给它；
///   不读工作目录里的项目文件（`-na`：项目的 `.pi/` 设置、扩展与 MCP 配置都不信任），也不加载 skill、上下文文件、提示词模板；
/// - 系统提示整份替换（`--system-prompt` 盖过 `SYSTEM.md`）；Pi 只在没给 `--append-system-prompt` 时才去找 `APPEND_SYSTEM.md`
///   追加上去，所以给一个空的追加项挡掉它（空串不追加任何东西）；
/// - 工具只有扩展登记的与内置的 `read,grep,find,ls`（`-nbt` 关掉内置工具、留着扩展的，`+名字` 再加回这几个）；
/// - 图随 `prompt` 的 `images` 交；模型能不能看图看 `get_state` 里模型的 `input`；
/// - 思考强度原样交给 `--thinking`（Pi 自己按模型支持的档位夹取）；就地换走 `set_model`（`提供方/模型` 拆开）再 `set_thinking_level`
///   （换模型时 Pi 会按新模型重取强度，所以强度在后）；都只改这个进程，不写 Pi 的设置；
/// - 用 Claude 订阅时把请求标成 Claude Code 的（随包的扩展 claude-subscription.ts，见它的头注释）：`-ne` 下用户自己装的同类扩展不加载，
///   不带这些标识的订阅请求会扣额外用量；
/// - 提示缓存用长的一档（`PI_CACHE_RETENTION=long`：Anthropic 1 小时，OpenAI 24 小时，提供方不支持的照常）；
/// - 开新会话走 `new_session`：Pi 按启动参数重建整个运行时（扩展与它起的工具服务都重起），所以就地换过的模型与强度随后再交一次；
/// - 发话一律带 `streamingBehavior: steer`：正忙时 Pi 在当前回合的工具调用做完后、下一次请求模型前把它交给模型，空闲时照常开始一轮；
/// - 一轮从第一个 `agent_start` 到 `agent_settled`（重试、压缩、插话都在其中）；
/// - 正在说的话（拼法见 `DraftParts`）：段号是 `contentIndex`，`message_update` 的 `text_delta` 追加（RPC 只发增量，见 Pi 的 docs/json.md
///   「Reconstruct streaming messages」），`text_end` 与 `message_end` 给定稿；开出工具调用、停下或出错后这条不再算。
@MainActor
final class PiBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var process: ChildProcess?
    private let replies = PendingReplies<String, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: CueBrainError.rejected(String(localized: "没有及时回应")))
    private var nextID = 0
    private(set) var seesImages = false
    static let subscription = Bundle.module.url(forResource: "claude-subscription", withExtension: "ts")!
    static let tools = Bundle.module.url(forResource: "cue-tools", withExtension: "ts")!

    /// 本机的 Claude Code（`claude-subscription.ts` 取它的版本号）：先找大脑的 PATH，再找常见安装目录；没有就交 `claude`，扩展用保底版本号。
    private static func claude(_ config: CueBrainConfig) -> String {
        let path = (config.environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let locator = ExecutableLocator(searchDirectories: path + ExecutableLocator.standard.searchDirectories)
        return locator.candidates(AgentKind.claudeCode.command).first?.path ?? AgentKind.claudeCode.command
    }
    /// 就地换过的模型与强度（`configure`）：开新会话后 Pi 回到启动参数，要再交一次
    private var configured: (model: String?, effort: PiThinkingLevel?) = (nil, nil)
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
            var arguments = [
                "--mode", "rpc", "--no-session", "--offline", "-ne", "-na", "-e", Self.tools.path, "-e", Self.subscription.path,
                "-ns", "-nc", "-np", "--no-themes", "--system-prompt", prompt.path, "--append-system-prompt", "", "-nbt", "--tools", "+read,+grep,+find,+ls",
            ]
            if let model = config.model { arguments += ["--model", model] }
            if let effort = config.effort { arguments += ["--thinking", effort.rawValue] }
            let process = try await ChildProcess(
                config.executable, arguments, directory: config.workingDirectory, environment: BrainSession.environment(config, [
                    "PI_CACHE_RETENTION": "long", "CUEPAD_CLAUDE": Self.claude(config), "CUEPAD_CUE_MCP": jsonString(config.mcp),
                ]),
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

    func newSession() async throws {
        _ = try await command(["type": "new_session"])
        if configured.model != nil || configured.effort != nil {
            try await apply(model: configured.model, effort: configured.effort)
        } else {
            adopt(try await command(["type": "get_state"])["data"]?["model"])
        }
    }

    func configure(model: String?, effort: PiThinkingLevel?) async throws {
        try await apply(model: model, effort: effort)
        configured = (model ?? configured.model, effort ?? configured.effort)
    }

    private func apply(model: String?, effort: PiThinkingLevel?) async throws {
        if let model {
            let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CueBrainError.rejected(String(localized: "Pi 的模型要写成 提供方/模型：\(model)")) }
            adopt(try await command(["type": "set_model", "provider": .string(parts[0]), "modelId": .string(parts[1])])["data"])
        }
        if let effort { _ = try await command(["type": "set_thinking_level", "level": .string(effort.rawValue)]) }
    }

    /// 在用的模型（Pi 的 Model 对象）：能不能看图。
    private func adopt(_ model: JSONValue?) {
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
        guard reply["success"]?.bool == true else { throw CueBrainError.rejected(reply["error"]?.string ?? String(localized: "未知错误")) }
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
            session.emit(.tool(id: id, name: name, arguments: String(decoding: (event["args"] ?? [:]).data, as: UTF8.self)))
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
            if used > 0 { session.emit(.context(used: used)) }
        }
        let stop = message["stopReason"]?.string
        // 被 abort 停下的是 "aborted"，不算出错；之后成功的请求（重试）清掉前面的错
        turn?.error = stop == "error" ? (message["errorMessage"]?.string ?? String(localized: "未知错误")) : nil
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

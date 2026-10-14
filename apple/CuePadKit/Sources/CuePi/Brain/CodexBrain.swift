#if os(macOS)
import CueStore
import Foundation

/// Codex 当大脑：`codex app-server`，经接入里的 `CodexRPC`（协议见 https://developers.openai.com/codex/app-server ；
/// 本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// - 线程是临时的（`thread/start` 的 `ephemeral`）：不写会话文件，不进 Codex 的历史；
/// - 系统提示经 `baseInstructions` 整份替换内置提示（与配置里的 `model_instructions_file` 同一处，参数优先）；
/// - 沙箱只读、从不请求批准：Codex 读文件靠 shell，写入被沙箱拒绝；
/// - MCP：先读出用户配置里的 MCP 服务（`config/read`），在这个线程上逐个停用，只开 CuePad 的 `cuepad`；
/// - 关掉会在 Cue 身上留下痕迹或替它动手的功能（见 `disabledFeatures`），回合结束不跑用户的 `notify`、不联网搜索；
/// - 图以 data URL 随输入交；模型能不能看图、支持哪些强度都看 `model/list` 里的这个模型；
/// - 思考强度按 `model/list` 里这个模型支持的档位夹取（`PiThinkingLevel.clamped`），随 `turn/start` 给；
/// - 正忙时说的话经 `turn/steer` 并进当前这一轮；这一轮恰好已经结束（steer 被拒）就开新的一轮。
@MainActor
final class CodexBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var rpc: CodexRPC?
    private var thread: String?
    /// 交给 `turn/start` 的强度（已夹到模型支持的档位）
    private var effort: String?
    private(set) var seesImages = false
    /// 进行中的一轮
    private var turn: Turn?
    private struct Turn {
        let id: String
        var reply: String?
    }

    /// 停用的功能：会写 Codex 自己的记忆与时间线（memories、chronicle），会跑用户配置的钩子（hooks，也就不会报给 CuePad 成一个会话），
    /// 或会给模型加上读文件以外的能力（apps、plugins、computer_use、browser_use、image_generation、multi_agent）。
    static let disabledFeatures = ["memories", "chronicle", "hooks", "apps", "plugins", "computer_use", "browser_use", "image_generation", "multi_agent"]

    func start(_ config: CueBrainConfig) async throws {
        do {
            let rpc = try await CodexRPC.launch(
                config.executable, arguments: ["-c", "notify=[]", "-c", "web_search=\"disabled\""] + Self.disabledFeatures.flatMap { ["--disable", $0] },
                environment: BrainSession.environment(config), directory: config.workingDirectory)
            self.rpc = rpc
            rpc.onNotification = { [weak self] in self?.notification($0, $1) }
            let process = rpc.process
            rpc.onClose = { [weak self] in
                Task { self?.session.exited(await process?.exited()) }
            }
            try await threadStart(config, on: rpc)
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    private func threadStart(_ config: CueBrainConfig, on rpc: CodexRPC) async throws {
        let effective = try await rpc.call("config/read", [:])
        let userServers = ((effective["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?.keys ?? [:].keys
        var overrides: [String: Any] = Dictionary(uniqueKeysWithValues: userServers.map { ("mcp_servers.\($0).enabled", false) })
        overrides["mcp_servers.cuepad"] = ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]
        var params: [String: Any] = [
            "cwd": config.workingDirectory.path, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
            "baseInstructions": config.systemPrompt, "config": overrides,
        ]
        if let model = config.model { params["model"] = model }
        let started = try await rpc.call("thread/start", params)
        thread = (started["thread"] as? [String: Any])?["id"] as? String
        let model = try await CodexModel.list(rpc, hidden: true).first { $0.id == started["model"] as? String }
        seesImages = model?.seesImages == true
        if let level = config.effort, let model { effort = CodexModel.effort(level.clamped(to: model.efforts)) }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let rpc, let thread else { throw CueBrainError.notRunning }
        let input = CodexRPC.input(text: text, images: images)
        if let active = turn?.id {
            do {
                try await rpc.call("turn/steer", ["threadId": thread, "input": input, "expectedTurnId": active])
                return
            } catch CodexRPCError.server {
                // 这一轮刚好结束：下面开新的一轮
            }
        }
        var params: [String: Any] = ["threadId": thread, "input": input]
        if let effort { params["effort"] = effort }
        let started = try await rpc.call("turn/start", params)
        if let id = (started["turn"] as? [String: Any])?["id"] as? String { beginTurn(id) }
    }

    func abort() async throws {
        guard let rpc, let thread, let active = turn?.id else { return }
        try await rpc.call("turn/interrupt", ["threadId": thread, "turnId": active])
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        thread = nil
        let process = rpc?.process
        return { await process?.stop() }
    }

    /// `turn/start` 的回应与 `turn/started` 通知谁先到都算开始，只报一次。
    private func beginTurn(_ id: String) {
        guard turn?.id != id else { return }
        turn = Turn(id: id)
        session.emit(.turnStarted)
    }

    private func notification(_ method: String, _ params: CodexRPC.Object) {
        switch method {
        case "turn/started":
            if let id = (params["turn"] as? [String: Any])?["id"] as? String { beginTurn(id) }
        case "item/completed":
            // 只认给你看的回答，过程中的说明（commentary）不算
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                  item["phase"] as? String != "commentary", let text = item["text"] as? String else { return }
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { turn?.reply = reply }
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any], let last = usage["last"] as? [String: Any],
                  let input = last["inputTokens"] as? Int else { return }
            // inputTokens 已含缓存命中（cachedInputTokens 是其中一部分）
            session.emit(.context(used: input, window: usage["modelContextWindow"] as? Int))
        case "turn/completed":
            let completed = params["turn"] as? [String: Any]
            let finished = turn
            turn = nil
            let status = completed?["status"] as? String
            if status != "interrupted", let reply = finished?.reply { session.emit(.reply(reply)) }
            if status == "failed" { session.emit(.failed(CodexModel.failure(of: completed))) }
            session.emit(.turnFinished)
        default:
            break
        }
    }
}
#endif

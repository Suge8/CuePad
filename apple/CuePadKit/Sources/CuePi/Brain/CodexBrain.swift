#if os(macOS)
import CueStore
import Foundation

/// Codex 当大脑：`codex app-server`（stdio 上的 JSON-RPC，协议见 https://developers.openai.com/codex/app-server ；
/// 本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// - 线程是临时的（`thread/start` 的 `ephemeral`）：不写会话文件，不进 Codex 的历史；
/// - 系统提示经 `baseInstructions` 整份替换内置提示（与配置里的 `model_instructions_file` 同一处，参数优先）；
/// - 沙箱只读、从不请求批准：Codex 读文件靠 shell，写入被沙箱拒绝；
/// - MCP：先读出用户配置里的 MCP 服务（`config/read`），在这个线程上逐个停用，只开 CuePad 的 `cuepad`；
/// - 关掉会在 Cue 身上留下痕迹或替它动手的功能（见 `disabledFeatures`），回合结束不跑用户的 `notify`、不联网搜索；
/// - 思考强度按 `model/list` 里这个模型支持的档位夹取（见 `effort(_:supported:)`），随 `turn/start` 给；
/// - 正忙时说的话经 `turn/steer` 并进当前这一轮；这一轮恰好已经结束（steer 被拒）就开新的一轮。
actor CodexBrain: CueBrain {
    nonisolated let events: AsyncStream<CueBrainEvent>
    private let emit: AsyncStream<CueBrainEvent>.Continuation
    private var process: BrainProcess?
    private var runner: Task<Void, Never>?
    private var pending = PendingReplies()
    private var nextID = 0
    private var thread: String?
    /// 交给 `turn/start` 的强度（已夹到模型支持的档位）
    private var effort: String?
    /// 进行中的一轮
    private var turn: Turn?
    private struct Turn {
        let id: String
        var reply: String?
    }

    /// 停用的功能：会写 Codex 自己的记忆与时间线（memories、chronicle），会跑用户配置的钩子（hooks），
    /// 或会给模型加上读文件以外的能力（apps、plugins、computer_use、browser_use、image_generation、multi_agent）。
    static let disabledFeatures = ["memories", "chronicle", "hooks", "apps", "plugins", "computer_use", "browser_use", "image_generation", "multi_agent"]

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
            throw error
        }
    }

    private func launch(_ config: CueBrainConfig) async throws {
        let arguments = ["app-server", "-c", "notify=[]", "-c", "web_search=\"disabled\""]
            + Self.disabledFeatures.flatMap { ["--disable", $0] }
        let process = try BrainProcess(
            executable: config.executable, arguments: arguments, directory: config.workingDirectory, environment: brainEnvironment(config))
        self.process = process
        runner = Task { await self.run(process) }

        _ = try await request("initialize", ["clientInfo": ["name": "cuepad", "title": "CuePad", "version": "1"], "capabilities": ["experimentalApi": false, "requestAttestation": false]])
        try process.write(["jsonrpc": "2.0", "method": "initialized", "params": [:] as [String: Any]])
        let effective = try await request("config/read", [:])
        let userServers = ((effective["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?.keys ?? [:].keys
        var overrides: [String: Any] = Dictionary(uniqueKeysWithValues: userServers.map { ("mcp_servers.\($0).enabled", false) })
        overrides["mcp_servers.cuepad"] = ["command": config.mcp[0], "args": Array(config.mcp.dropFirst()), "env": config.environment]
        var params: [String: Any] = [
            "cwd": config.workingDirectory.path, "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
            "baseInstructions": config.systemPrompt, "config": overrides,
        ]
        if let model = config.model { params["model"] = model }
        let started = try await request("thread/start", params)
        thread = (started["thread"] as? [String: Any])?["id"] as? String
        if let level = config.effort, let model = started["model"] as? String {
            let models = try await request("model/list", ["includeHidden": true, "limit": 500])["data"] as? [[String: Any]] ?? []
            let supported = (models.first { $0["id"] as? String == model }?["supportedReasoningEfforts"] as? [[String: Any]])?
                .compactMap { $0["reasoningEffort"] as? String }
            effort = Self.effort(level, supported: supported)
        }
    }

    /// Codex 的强度写法从低到高（`off` 对应 `none`）；模型列出支持的档位时取其中最近的一档（等距取低的），列不出就原样给。
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func effort(_ level: PiThinkingLevel, supported: [String]?) -> String {
        let wanted = level == .off ? "none" : level.rawValue
        guard let supported, !supported.contains(wanted), let target = efforts.firstIndex(of: wanted) else { return wanted }
        let ranked = supported.compactMap { name in efforts.firstIndex(of: name).map { (name, abs($0 - target), $0) } }
        return ranked.min { ($0.1, $0.2) < ($1.1, $1.2) }?.0 ?? wanted
    }

    func send(_ text: String) async throws {
        guard let thread else { throw CueBrainError.notRunning }
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": [] as [Any]]]
        if let active = turn?.id {
            do {
                _ = try await request("turn/steer", ["threadId": thread, "input": input, "expectedTurnId": active])
                return
            } catch CueBrainError.rejected {
                // 这一轮刚好结束：下面开新的一轮
            }
        }
        var params: [String: Any] = ["threadId": thread, "input": input]
        if let effort { params["effort"] = effort }
        let started = try await request("turn/start", params)
        if let id = (started["turn"] as? [String: Any])?["id"] as? String { beginTurn(id) }
    }

    func abort() async throws {
        guard let thread, let active = turn?.id else { return }
        _ = try await request("turn/interrupt", ["threadId": thread, "turnId": active])
    }

    func stop() async {
        await process?.stop()
        await runner?.value
        process = nil
        thread = nil
    }

    private func run(_ process: BrainProcess) async {
        let reason = await process.pump { self.receive($0) }
        pending.close()
        emit.yield(.exited(reason))
        emit.finish()
    }

    /// JSON-RPC 请求，返回 `result`；`error` 抛 `rejected`。
    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let process else { throw CueBrainError.notRunning }
        nextID += 1
        let id = nextID
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending.add(String(id), continuation)
            do { try process.write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) } catch { pending.fail(String(id), error) }
        }
        if let error = reply["error"] as? [String: Any] { throw CueBrainError.rejected(error["message"] as? String ?? "未知错误") }
        return reply["result"] as? [String: Any] ?? [:]
    }

    /// `turn/start` 的回应与 `turn/started` 通知谁先到都算开始，只报一次。
    private func beginTurn(_ id: String) {
        guard turn?.id != id else { return }
        turn = Turn(id: id)
        emit.yield(.turnStarted)
    }

    private func receive(_ line: Data) {
        guard let message = jsonObject(line) else { return }
        let method = message["method"] as? String
        if let id = message["id"] {
            if let method {
                // 服务端发来的请求（批准、MCP 征询……）：Cue 不答应任何请求，回错误免得这一轮卡住
                try? process?.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "CuePad does not handle \(method)"]])
            } else if let id = (id as? Int).map(String.init) {
                _ = pending.resolve(id, message)
            }
            return
        }
        guard let method, let params = message["params"] as? [String: Any] else { return }
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
            emit.yield(.context(used: input, window: usage["modelContextWindow"] as? Int))
        case "turn/completed":
            let completed = params["turn"] as? [String: Any]
            let finished = turn
            turn = nil
            let status = completed?["status"] as? String
            if status != "interrupted", let reply = finished?.reply { emit.yield(.reply(reply)) }
            if status == "failed" {
                emit.yield(.failed((completed?["error"] as? [String: Any])?["message"] as? String ?? "未知错误"))
            }
            emit.yield(.turnFinished)
        default:
            break
        }
    }
}
#endif

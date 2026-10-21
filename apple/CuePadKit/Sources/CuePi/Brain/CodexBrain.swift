#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Codex 当大脑：`codex app-server`，经接入里的 `CodexRPC`（协议见 https://developers.openai.com/codex/app-server ；
/// 本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// - 线程是临时的（`thread/start` 的 `ephemeral`）：不写会话文件，不进 Codex 的历史；开新会话就是另开一个这样的线程（模型与强度每轮随 `turn/start` 给，不受影响）；
/// - 系统提示经 `baseInstructions` 整份替换内置提示（与配置里的 `model_instructions_file` 同一处，参数优先）；
/// - 沙箱只读、从不请求批准：Codex 读文件靠 shell，写入被沙箱拒绝；
/// - MCP：先读出用户配置里的 MCP 服务（`config/read`），在这个线程上逐个停用，只开 CuePad 的 `cuepad`，它的工具一律放行
///   （`default_tools_approval_mode`）：新版 Codex 的 MCP 工具默认要批准，在"从不请求批准"下就是直接拒掉；
/// - 关掉会在 Cue 身上留下痕迹或替它动手的功能（见 `disabledFeatures`），回合结束不跑用户的 `notify`、不联网搜索；
/// - 模型看到的输入只有系统提示、沙箱说明与环境（工作目录、日期）：用户的 skill 清单（`skills.include_instructions`）、
///   工作目录里的 AGENTS.md（`project_doc_max_bytes` 为 0）、子代理的角色说明与工具（`agents.enabled`；只停用 `multi_agent` 功能不够，
///   模型表声明了 v2 的模型照样开着）、协作模式说明（`include_collaboration_mode_instructions`）都关掉，见 `overrides`；
///   `<CODEX_HOME>/AGENTS.md` 没有开关（只换配置目录才挡得住，换了会丢登录），用户写了就会进来；
/// - 图以 data URL 随输入交；模型能不能看图、支持哪些强度都看 `model/list` 里的这个模型；
/// - 模型与思考强度每轮随 `turn/start` 给（就地换就是改下一轮给的）：强度按 `model/list` 里这个模型支持的档位夹取（`PiThinkingLevel.clamped`）；
/// - 正忙时说的话经 `turn/steer` 并进当前这一轮；这一轮恰好已经结束（steer 被拒）就开新的一轮；
/// - 正在说的话用 `CodexRPC` 累积好的这个线程的（`onDraft`）：过程中的说明（commentary）说完、停下与失败的一轮它已清掉，留下的只有给你看的回答。
@MainActor
final class CodexBrain: CueBrain {
    private let session = BrainSession()
    var events: AsyncStream<CueBrainEvent> { session.events }
    private var rpc: CodexRPC?
    private var thread: String?
    /// 开线程的参数（`thread/start`）：开新会话时原样再开一个
    private var threadParams: JSONValue = [:]
    /// `model/list` 里的模型（连隐藏的）：就地换模型时认模型、取它支持的强度
    private var models: [CodexModel] = []
    /// 在用的模型（没给时是 `thread/start` 定下的默认）与要的强度：每轮随 `turn/start` 给
    private var model: CodexModel?
    private var level: PiThinkingLevel?
    var seesImages: Bool { model?.seesImages == true }
    private var turn: Turn?
    private struct Turn {
        let id: String
    }

    /// 停用的功能：会写 Codex 自己的记忆与时间线（memories、chronicle），会跑用户配置的钩子（hooks，也就不会报给 CuePad 成一个会话），
    /// 或会给模型加上读文件以外的能力（apps、plugins、computer_use、browser_use、image_generation）。
    static let disabledFeatures = ["memories", "chronicle", "hooks", "apps", "plugins", "computer_use", "browser_use", "image_generation"]
    /// 盖过用户配置的项（`-c`，值是 TOML），键名见 Codex 的 config.schema.json。
    static let overrides = [
        "notify=[]", #"web_search="disabled""#, "skills.include_instructions=false", "project_doc_max_bytes=0", "agents.enabled=false",
        "include_collaboration_mode_instructions=false",
    ]

    func start(_ config: CueBrainConfig) async throws {
        do {
            let rpc = try await CodexRPC.launch(
                config.executable, arguments: Self.overrides.flatMap { ["-c", $0] } + Self.disabledFeatures.flatMap { ["--disable", $0] },
                environment: BrainSession.environment(config), directory: config.workingDirectory)
            self.rpc = rpc
            rpc.onNotification = { [weak self] in self?.notification($0, $1) }
            rpc.onDraft = { [weak self] thread, draft in
                guard let self, thread == self.thread else { return }
                session.emit(.speaking(draft))
            }
            let process = rpc.process
            rpc.onClose = { [weak self] in
                Task { self?.session.exited(await process?.exited()) }
            }
            try await threadStart(config, on: rpc)
            level = config.effort
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    private func threadStart(_ config: CueBrainConfig, on rpc: CodexRPC) async throws {
        let effective = try await rpc.call("config/read", [:])
        let userServers = effective["config"]?["mcp_servers"]?.object?.keys ?? [:].keys
        var overrides: [String: JSONValue] = Dictionary(uniqueKeysWithValues: userServers.map { ("mcp_servers.\($0).enabled", false) })
        overrides["mcp_servers.\(CueMCPServer.name)"] = [
            "command": .string(config.mcp[0]), "args": .array(config.mcp.dropFirst().map(JSONValue.string)),
            "env": .object(config.environment.mapValues(JSONValue.string)), "default_tools_approval_mode": "approve",
        ]
        var params: [String: JSONValue] = [
            "cwd": .string(config.workingDirectory.path), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
            "baseInstructions": .string(config.systemPrompt), "config": .object(overrides),
        ]
        if let model = config.model { params["model"] = .string(model) }
        threadParams = .object(params)
        let started = try await rpc.call("thread/start", threadParams)
        thread = started["thread"]?["id"]?.string
        models = try await CodexModel.list(rpc, hidden: true)
        model = models.first { $0.id == started["model"]?.string }
    }

    func newSession() async throws {
        guard let rpc, thread != nil else { throw CueBrainError.notRunning }
        thread = try await rpc.call("thread/start", threadParams)["thread"]?["id"]?.string
    }

    func configure(model id: String?, effort: PiThinkingLevel?) async throws {
        guard thread != nil else { throw CueBrainError.notRunning }
        if let id {
            guard let found = models.first(where: { $0.id == id }) else { throw CueBrainError.rejected("Codex 没有模型 \(id)") }
            model = found
        }
        if let effort { level = effort }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let rpc, let thread else { throw CueBrainError.notRunning }
        let input = CodexRPC.input(text: text, images: images)
        if let active = turn?.id {
            do {
                try await rpc.call("turn/steer", ["threadId": .string(thread), "input": .array(input), "expectedTurnId": .string(active)])
                return
            } catch CodexRPCError.server {
                // 这一轮刚好结束：下面开新的一轮
            }
        }
        var params: [String: JSONValue] = ["threadId": .string(thread), "input": .array(input)]
        if let model {
            params["model"] = .string(model.id)
            if let level { params["effort"] = .string(CodexModel.effort(level.clamped(to: model.efforts))) }
        }
        let started = try await rpc.call("turn/start", .object(params))
        if let id = started["turn"]?["id"]?.string { beginTurn(id) }
    }

    func abort() async throws {
        guard let rpc, let thread, let active = turn?.id else { return }
        try await rpc.call("turn/interrupt", ["threadId": .string(thread), "turnId": .string(active)])
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

    private func notification(_ method: String, _ params: JSONValue) {
        switch method {
        case "turn/started":
            if let id = params["turn"]?["id"]?.string { beginTurn(id) }
        case "item/started":
            guard turn != nil, let item = params["item"] else { return }
            switch item["type"]?.string {
            case "mcpToolCall":
                let name = item["tool"]?.string ?? "?"
                session.emit(.tool(id: item["id"]?.string ?? "", name: name, arguments: String(decoding: (item["arguments"] ?? [:]).data, as: UTF8.self)))
            case "commandExecution":
                let command = jsonString(["command": item["command"]?.string ?? ""])
                session.emit(.tool(id: item["id"]?.string ?? "", name: "bash", arguments: command))
            default: break
            }
        case "item/completed":
            guard let item = params["item"] else { return }
            let id = item["id"]?.string ?? "", failed = ["failed", "declined"].contains(item["status"]?.string)
            switch item["type"]?.string {
            case "mcpToolCall" where turn != nil:
                let error = item["error"]?["message"]?.string
                let result = error ?? brainText(item["result"]?["content"])
                session.emit(.toolDone(id: id, result: result, failed: failed || error != nil))
            case "commandExecution" where turn != nil:
                session.emit(.toolDone(id: id, result: item["aggregatedOutput"]?.string ?? "", failed: failed))
            default: break
            }
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], let input = usage["last"]?["inputTokens"]?.int else { return }
            // inputTokens 已含缓存命中（cachedInputTokens 是其中一部分）
            session.emit(.context(used: input, window: usage["modelContextWindow"]?.int))
        case "turn/completed":
            let completed = params["turn"]
            turn = nil
            if completed?["status"]?.string == "failed" { session.emit(.failed(CodexModel.failure(of: completed))) }
            session.emit(.turnFinished)
        default:
            break
        }
    }
}
#endif

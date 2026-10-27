#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// CuePad 起的一个 `codex app-server` 进程与它上面 CuePad 开的那个线程（`thread`）的驱动：这个线程的一轮只在这里判，翻成
/// `TurnEvent` 同步交给 `onEvent`（按到达先后）。托管会话（`CodexRuntime` 起的进程，一轮接到桥上）与 Cue 的大脑（`start(_:)`）
/// 是同一个驱动的两种开法。协议见 https://developers.openai.com/codex/app-server （本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// - 一轮开始：`turn/start` 的回应与 `turn/started` 通知谁先到算谁，按轮的 id 只报一次（已经结束的那一轮的回应晚到不再报）；
/// - 一轮结束：这一轮的 `turn/completed`（别的轮的不算：停下旧的一轮紧接着开新的一轮时，旧的结束可能晚到）。失败的先报 `failed`：
///   这一轮不再重试的 `error` 通知的原文，没有就用 `turn.error`。不看线程状态：失败时 systemError 先于原文与 `turn/completed` 到（实测 0.162.1）；
/// - 工具是这一轮里的 `mcpToolCall` 与 `commandExecution` 项（命令记作 `bash`）；用量是最近一次请求的 `inputTokens`（已含缓存命中）与 `modelContextWindow`；
/// - 正在说的话是 `CodexRPC` 累积好的这个线程的（`onDraft`）：过程中的说明说完、停下与失败的一轮它已清掉，留下的只有给你看的回答；
/// - 子线程（子代理）与线程之外的事不在这里：每条通知处理完原样转给 `onNotification`，服务端请求由开它的一方接（`CodexRPC.onRequest`）。
@MainActor
final class CodexDriver {
    private(set) var rpc: CodexRPC?
    /// CuePad 开的线程（`thread/start`、`thread/resume`，经 `open`）
    private(set) var thread: String?
    /// 在跑的这一轮与最近结束的一轮（挡住晚到的回应）
    private var turn: String?
    private var finishedTurn: String?
    /// 这一轮不再重试的 `error` 通知的原文
    private var lastError: String?
    var onEvent: (TurnEvent) -> Void = { _ in }
    var onNotification: (String, JSONValue) -> Void = { _, _ in }

    // 以下只有大脑用（托管会话的模型、强度归 `thread/settings/update`）
    private let outlet = BrainSession()
    /// 开线程的参数：开新会话时原样再开一个
    private var threadParams: JSONValue = [:]
    /// `model/list` 里的模型（连隐藏的）：就地换模型时认模型、取它支持的强度
    private var models: [CodexModel] = []
    /// 在用的模型（没给时是 `thread/start` 定下的默认）与要的强度：每轮随 `turn/start` 给
    private var model: CodexModel?
    private var level: PiThinkingLevel?

    /// 起进程并握手（失败时进程已停掉），接上它的通知；进程退出报 `exited`（`stop` 让它退的为 nil）。
    @discardableResult
    func launch(_ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil) async throws -> CodexRPC {
        let rpc = try await CodexRPC.launch(executable, arguments: arguments, environment: environment, directory: directory)
        self.rpc = rpc
        rpc.onNotification = { [weak self] in self?.notification($0, $1) }
        rpc.onDraft = { [weak self] thread, draft in
            guard let self, thread == self.thread else { return }
            onEvent(.speaking(draft))
        }
        let process = rpc.process
        rpc.onClose = { [weak self] in
            Task { [weak self] in
                let reason = await process?.exited()
                self?.onEvent(.exited(reason))
            }
        }
        return rpc
    }

    /// 开或接着一个线程（`thread/start`、`thread/resume`），之后报的是它的事。
    @discardableResult
    func open(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let rpc else { throw HostedSessionError.notRunning }
        let result = try await rpc.call(method, params)
        thread = result["thread"]?["id"]?.string
        turn = nil
        return result
    }

    /// 开一轮（`options` 是 `turn/start` 的其余参数）。
    func startTurn(_ input: [JSONValue], options: [String: JSONValue] = [:]) async throws {
        guard let rpc, let thread else { throw HostedSessionError.notRunning }
        let params = options.merging(["threadId": .string(thread), "input": .array(input)]) { $1 }
        let started = try await rpc.call("turn/start", .object(params))
        if let id = started["turn"]?["id"]?.string { begin(id) }
    }

    /// 停下在跑的这一轮，等它真的结束了才回（回应与它的 `turn/completed` 同时到）；没有在跑的什么都不做。
    func interrupt() async throws {
        guard let rpc, let thread, let turn else { return }
        do {
            try await rpc.call("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
        } catch CodexRPCError.server(-32600, _) {
            // 这一轮在问与停之间自己结束了（"no active turn to interrupt"）
        }
    }

    private func begin(_ id: String) {
        guard turn != id, finishedTurn != id else { return }
        turn = id
        lastError = nil
        onEvent(.turnStarted)
    }

    private func finish(failure: String?) {
        finishedTurn = turn
        turn = nil
        lastError = nil
        if let failure { onEvent(.failed(failure)) }
        onEvent(.turnFinished)
    }

    private func notification(_ method: String, _ params: JSONValue) {
        if let thread, params["threadId"]?.string == thread { own(method, params) }
        onNotification(method, params)
    }

    private func own(_ method: String, _ params: JSONValue) {
        switch method {
        case "turn/started":
            if let id = params["turn"]?["id"]?.string { begin(id) }
        case "turn/completed":
            let completed = params["turn"]
            guard turn != nil, completed?["id"]?.string == turn else {
                finishedTurn = completed?["id"]?.string
                return
            }
            finish(failure: completed?["status"]?.string == "failed" ? lastError ?? CodexModel.failure(of: completed) : nil)
        case "error" where params["willRetry"]?.bool != true:
            lastError = CodexModel.failure(of: params)
        case "item/started" where turn != nil:
            guard let item = params["item"] else { return }
            let id = item["id"]?.string ?? ""
            switch item["type"]?.string {
            case "mcpToolCall":
                onEvent(.tool(id: id, name: item["tool"]?.string ?? "?", arguments: String(decoding: (item["arguments"] ?? [:]).data, as: UTF8.self)))
            case "commandExecution":
                onEvent(.tool(id: id, name: "bash", arguments: jsonString(["command": item["command"]?.string ?? ""])))
            default: break
            }
        case "item/completed" where turn != nil:
            guard let item = params["item"] else { return }
            let id = item["id"]?.string ?? "", failed = ["failed", "declined"].contains(item["status"]?.string)
            switch item["type"]?.string {
            case "mcpToolCall":
                let error = item["error"]?["message"]?.string
                onEvent(.toolDone(id: id, result: error ?? brainText(item["result"]?["content"]), failed: failed || error != nil))
            case "commandExecution":
                onEvent(.toolDone(id: id, result: item["aggregatedOutput"]?.string ?? "", failed: failed))
            default: break
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            if let input = usage?["last"]?["inputTokens"]?.int { onEvent(.context(used: input, window: usage?["modelContextWindow"]?.int)) }
        default:
            break
        }
    }
}

/// Cue 的大脑这样开：
/// - 线程是临时的（`thread/start` 的 `ephemeral`）：不写会话文件，不进 Codex 的历史；开新会话就是另开一个这样的线程；
/// - 系统提示经 `baseInstructions` 整份替换内置提示（与配置里的 `model_instructions_file` 同一处，参数优先）；
/// - 沙箱只读、从不请求批准：Codex 读文件靠 shell，写入被沙箱拒绝；
/// - MCP：先读出用户配置里的 MCP 服务（`config/read`），在这个线程上逐个停用，只开 CuePad 的 `cuepad`，它的工具一律放行
///   （`default_tools_approval_mode`）：新版 Codex 的 MCP 工具默认要批准，在"从不请求批准"下就是直接拒掉；
/// - 关掉会在 Cue 身上留下痕迹或替它动手的功能（见 `disabledFeatures`），回合结束不跑用户的 `notify`、不联网搜索；
/// - 模型看到的输入只有系统提示与环境（工作目录、日期）。Codex 自己的权限说明（`include_permissions_instructions`："只读沙箱、
///   从不请求批准、不许提权"）关掉：它说的是大脑自己的沙箱，Cue 回答会话的权限确认时会当成会话的规矩、照它拒掉会话写工作区。
///   用户的 skill 清单（`skills.include_instructions`）、
///   工作目录里的 AGENTS.md（`project_doc_max_bytes` 为 0）、子代理的角色说明与工具（`agents.enabled`；只停用 `multi_agent` 功能不够，
///   模型表声明了 v2 的模型照样开着）、协作模式说明（`include_collaboration_mode_instructions`）也都关掉，见 `overrides`；
///   `<CODEX_HOME>/AGENTS.md` 没有开关（只换配置目录才挡得住，换了会丢登录），用户写了就会进来；
/// - 图以 data URL 随输入交；模型能不能看图、支持哪些强度都看 `model/list` 里的这个模型；
/// - 模型与思考强度每轮随 `turn/start` 给（就地换就是改下一轮给的）：强度按 `model/list` 里这个模型支持的档位夹取（`PiThinkingLevel.clamped`）；
/// - 正忙时说的话经 `turn/steer` 并进当前这一轮；这一轮恰好已经结束（steer 被拒）就开新的一轮。
extension CodexDriver: HostedSession {
    /// 停用的功能：会写 Codex 自己的记忆与时间线（memories、chronicle），会跑用户配置的钩子（hooks，也就不会报给 CuePad 成一个会话），
    /// 或会给模型加上读文件以外的能力（apps、plugins、computer_use、browser_use、image_generation）。
    static let disabledFeatures = ["memories", "chronicle", "hooks", "apps", "plugins", "computer_use", "browser_use", "image_generation"]
    /// 盖过用户配置的项（`-c`，值是 TOML），键名见 Codex 的 config.schema.json。
    static let overrides = [
        "notify=[]", #"web_search="disabled""#, "skills.include_instructions=false", "project_doc_max_bytes=0", "agents.enabled=false",
        "include_collaboration_mode_instructions=false", "include_permissions_instructions=false",
    ]

    var events: AsyncStream<TurnEvent> { outlet.events }
    var seesImages: Bool { model?.seesImages == true }

    func start(_ config: CueBrainConfig) async throws {
        onEvent = { [outlet] event in
            if case .exited(let reason) = event { outlet.exited(reason) } else { outlet.emit(event) }
        }
        do {
            let rpc = try await launch(
                config.executable, arguments: Self.overrides.flatMap { ["-c", $0] } + Self.disabledFeatures.flatMap { ["--disable", $0] },
                environment: BrainSession.environment(config), directory: config.workingDirectory)
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
            let started = try await open("thread/start", threadParams)
            models = try await CodexModel.list(rpc, hidden: true)
            model = models.first { $0.id == started["model"]?.string }
            level = config.effort
        } catch {
            await outlet.abandon(stop())
            throw error
        }
    }

    func newSession() async throws {
        guard thread != nil else { throw HostedSessionError.notRunning }
        try await open("thread/start", threadParams)
    }

    func configure(model id: String?, effort: PiThinkingLevel?) async throws {
        guard thread != nil else { throw HostedSessionError.notRunning }
        if let id {
            guard let found = models.first(where: { $0.id == id }) else { throw HostedSessionError.rejected(String(localized: "Codex 没有模型 \(id)")) }
            model = found
        }
        if let effort { level = effort }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let rpc, let thread else { throw HostedSessionError.notRunning }
        let input = CodexRPC.input(text: text, images: images)
        if let active = turn {
            do {
                try await rpc.call("turn/steer", ["threadId": .string(thread), "input": .array(input), "expectedTurnId": .string(active)])
                return
            } catch CodexRPCError.server {
                // 这一轮刚好结束：下面开新的一轮
            }
        }
        var options: [String: JSONValue] = [:]
        if let model {
            options["model"] = .string(model.id)
            if let level { options["effort"] = .string(CodexModel.effort(level.clamped(to: model.efforts))) }
        }
        try await startTurn(input, options: options)
    }

    func abort() async throws {
        try await interrupt()
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        thread = nil
        let process = rpc?.process
        return { await process?.stop() }
    }
}
#endif

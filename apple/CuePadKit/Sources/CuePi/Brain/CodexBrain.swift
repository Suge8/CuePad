#if os(macOS)
import CueAgent
import CueStore
import Foundation

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
@MainActor
final class CodexBrain: HostedSession {
    /// 停用的功能：会写 Codex 自己的记忆与时间线（memories、chronicle），会跑用户配置的钩子（hooks，也就不会报给 CuePad 成一个会话），
    /// 或会给模型加上读文件以外的能力（apps、plugins、computer_use、browser_use、image_generation）。
    static let disabledFeatures = ["memories", "chronicle", "hooks", "apps", "plugins", "computer_use", "browser_use", "image_generation"]
    /// 盖过用户配置的项（`-c`，值是 TOML），键名见 Codex 的 config.schema.json。
    static let overrides = [
        "notify=[]", #"web_search="disabled""#, "skills.include_instructions=false", "project_doc_max_bytes=0", "agents.enabled=false",
        "include_collaboration_mode_instructions=false", "include_permissions_instructions=false",
    ]

    private let outlet = BrainSession()
    private let driver = CodexDriver()
    /// 开线程的参数：开新会话时原样再开一个
    private var threadParams: JSONValue = [:]
    /// `model/list` 里的模型（连隐藏的）：就地换模型时认模型、取它支持的强度
    private var models: [CodexModel] = []
    /// 在用的模型（没给时是 `thread/start` 定下的默认）与要的强度：每轮随 `turn/start` 给
    private var model: CodexModel?
    private var level: PiThinkingLevel?

    var events: AsyncStream<TurnEvent> { outlet.events }
    var seesImages: Bool { model?.seesImages == true }

    func start(_ config: CueBrainConfig) async throws {
        driver.onEvent = { [outlet] event in
            if case .exited(let reason) = event { outlet.exited(reason) } else { outlet.emit(event) }
        }
        do {
            let rpc = try await driver.launch(
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
            let started = try await driver.open("thread/start", threadParams)
            models = try await CodexModel.list(rpc, hidden: true)
            model = models.first { $0.id == started["model"]?.string }
            level = config.effort
        } catch {
            await outlet.abandon(stop())
            throw error
        }
    }

    func newSession() async throws {
        guard driver.thread != nil else { throw HostedSessionError.notRunning }
        try await driver.open("thread/start", threadParams)
    }

    func configure(model id: String?, effort: PiThinkingLevel?) async throws {
        guard driver.thread != nil else { throw HostedSessionError.notRunning }
        if let id {
            guard let found = models.first(where: { $0.id == id }) else { throw HostedSessionError.rejected(String(localized: "Codex 没有模型 \(id)")) }
            model = found
        }
        if let effort { level = effort }
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let rpc = driver.rpc, let thread = driver.thread else { throw HostedSessionError.notRunning }
        let input = CodexRPC.input(text: text, images: images)
        if let active = driver.turn {
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
        try await driver.startTurn(input, options: options)
    }

    func stop() -> @concurrent @Sendable () async -> Void { driver.stop() }
}
#endif

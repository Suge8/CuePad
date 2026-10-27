#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// OpenCode 当大脑：自己起一台 `opencode serve --stdio`（`OpenCodeClient.serve`，生命随标准输入，不复用用户的后台服务），
/// 经与接入同一份的接口与事件流（`OpenCodeClient`、`OpenCodeEvent`、`OpenCodeDrafts`）说话。配置只经环境变量与内联配置，不改用户的文件：
/// - 内联配置（`OPENCODE_CONFIG_CONTENT`，见 `inlineConfig`）定义智能体 `cue`：`system` 整份替换系统提示；权限先全部拒绝，再放行读文件的三样
///   （`read`、`glob`、`grep`，连同工作目录外的路径）与 CuePad 的 MCP 工具；MCP 只开 CuePad 的 `cuepad`（策略拒绝 `mcp:*`、只放 `mcp:cuepad`，
///   用户配置里的 MCP 服务不起），不走 codemode（工具直接给模型）；不留快照；
/// - 不读工作目录的项目配置（`OPENCODE_DISABLE_PROJECT_CONFIG`）。用户全局的 AGENTS.md（OpenCode 配置目录里的）没有开关（只换配置目录
///   才挡得住，换了会丢用户配的提供方），写了就会进来——同 Codex 大脑对 `<CODEX_HOME>/AGENTS.md` 的取舍；
/// - 会话落在用户真实的库里（订阅登录、提供方凭据都在那里）：开会话时带标题（省掉起标题的那次模型调用），metadata 里标上
///   `cuepadBrain`（值是这台服务的 pid）；接入认这个标记跳过它们（`OpenCodeSessionInfo.isCueBrain`）。开新会话与停下时删掉旧会话；
///   起大脑时先删掉这个工作目录里服务已不在的带标记会话（崩溃留下的；同时在跑的另一个大脑的不动）；
/// - MCP 是起服务后异步连上的：起大脑时等 `/api/mcp` 报 `cuepad` 已连上（`mcp.status.changed` 时再看），之前说的话模型看不到它的工具；
/// - 说的话以 `steer` 交：空闲时开一轮，正忙时在下一个步骤边界并进这一轮；停下用 `interrupt`；
/// - 模型写成 `提供方/模型`，换模型与强度（模型的 `variant`，按 `OpenCodeModel.variant(for:)` 夹取）先在 `/api/model` 里认：
///   服务对不存在的模型也回 204；能不能看图看模型的 `capabilities.input`；
/// - 一轮是一次执行（`session.execution.*`）；正在说的话由 `OpenCodeDrafts` 累积；上下文是每一步的输入合计（`OpenCodeTokens.prompt`）；
///   工具名去掉 MCP 的前缀（`CueMCPServer.toolPrefix`）。事件流断了（服务卡住）就结束进程，报成退出。
@MainActor
final class OpenCodeBrain: HostedSession {
    private let session = BrainSession()
    var events: AsyncStream<TurnEvent> { session.events }
    private var process: ChildProcess?
    private var client: OpenCodeClient?
    private var directory = ""
    /// 开会话的请求体：开新会话时换上在用的模型再开
    private var create: Create?
    private var sessionID: String?
    private var models: [OpenCodeModel] = []
    private var model: OpenCodeModel?
    private var level: PiThinkingLevel?
    var seesImages: Bool { model?.seesImages == true }
    private var drafts = OpenCodeDrafts()
    /// 在跑的工具调用 → 名字（`tool.called` 不带名字，名字在它之前的 `tool.input.started` 里）
    private var toolNames: [String: String] = [:]
    /// MCP 服务的状态变了：等它连上的那一处醒来再看
    private let mcpChanges = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    nonisolated static let agent = "cue"

    private struct Create: Encodable {
        var agent = OpenCodeBrain.agent
        var title = "Cue"
        var metadata: OpenCodeSessionInfo.Metadata
        var location: OpenCodeLocation
        var model: OpenCodeModelRef
    }

    func start(_ config: CueBrainConfig) async throws {
        do {
            directory = config.workingDirectory.path
            let environment = BrainSession.environment(config, [
                "OPENCODE_CONFIG_CONTENT": jsonString(Self.inlineConfig(config)), "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
            ])
            let (process, client) = try await OpenCodeClient.serve(config.executable, environment: environment, directory: config.workingDirectory)
            self.process = process
            self.client = client
            Task { [weak self] in
                let reason = await process.exited()
                self?.session.exited(reason)
            }
            try await follow(client)
            try await sweep(client)
            try await withDeadline(AgentTimeouts.launch, orThrow: HostedSessionError.rejected(String(localized: "CuePad 的 MCP 服务没有及时连上"))) {
                try await self.mcpReady(client)
            }
            models = try await client.get(OpenCodeData<[OpenCodeModel]>.self, "/api/model", directory: directory).data
            let model = if let ref = config.model { try find(ref) } else {
                try await client.get(OpenCodeData<OpenCodeModel?>.self, "/api/model/default", directory: directory).data
            }
            guard let model else { throw HostedSessionError.rejected(String(localized: "OpenCode 没有可用的模型")) }
            self.model = model
            level = config.effort
            let create = Create(
                metadata: .init(cuepadBrain: process.pid), location: OpenCodeLocation(directory: directory),
                model: model.ref(level.flatMap(model.variant)))
            self.create = create
            sessionID = try await open(create, on: client)
        } catch {
            await session.abandon(stop())
            throw error
        }
    }

    /// 内联配置，键名见 OpenCode v2 的 config.schema.json。
    private static func inlineConfig(_ config: CueBrainConfig) -> [String: Any] {
        let allowed = ["read", "glob", "grep", "external_directory", "\(CueMCPServer.toolPrefix(on: .opencode))*"]
        let permissions = [["action": "*", "resource": "*", "effect": "deny"]] + allowed.map { ["action": $0, "resource": "*", "effect": "allow"] }
        return [
            "default_agent": agent, "snapshots": false,
            "agents": [agent: ["mode": "primary", "description": "Cue", "system": config.systemPrompt, "permissions": permissions]],
            "policies": [
                ["action": "integration.use", "resource": "mcp:*", "effect": "deny"],
                ["action": "integration.use", "resource": "mcp:\(CueMCPServer.name)", "effect": "allow"],
            ],
            "mcp": ["servers": [CueMCPServer.name: ["type": "local", "command": config.mcp, "codemode": false, "environment": config.environment]]],
        ]
    }

    /// 连上事件流（等到 `server.connected`），之后的事件交给 `received`。流断了而服务还在（不是 `stop()` 停的）就结束服务。
    private func follow(_ client: OpenCodeClient) async throws {
        let stream = client.events()
        try await withCheckedThrowingContinuation { (connected: CheckedContinuation<Void, any Error>) in
            Task { [weak self] in
                var connected = Optional(connected)
                do {
                    for try await event in stream {
                        if event.type == "server.connected" {
                            connected?.resume()
                            connected = nil
                        } else {
                            self?.received(event)
                        }
                    }
                    connected?.resume(throwing: HostedSessionError.notRunning)
                } catch {
                    connected?.resume(throwing: error)
                }
                if let self, self.client != nil { self.process?.end() }
            }
        }
    }

    /// 删掉这个工作目录里崩溃留下的大脑会话：带标记、起它的服务已不在。
    private func sweep(_ client: OpenCodeClient) async throws {
        for info in try await client.sessions("&directory=" + OpenCodeClient.escaped(directory)) {
            guard let pid = info.metadata?.cuepadBrain, PiProcess.running(pid: pid) == nil else { continue }
            try await client.call("DELETE", "/api/session/\(info.id)")
        }
    }

    private func mcpReady(_ client: OpenCodeClient) async throws {
        var changes = mcpChanges.stream.makeAsyncIterator()
        while true {
            let servers = try await client.get(OpenCodeData<[OpenCodeMCPServer]>.self, "/api/mcp", directory: directory).data
            let status = servers.first { $0.name == CueMCPServer.name }?.status
            switch status?.status {
            case "connected": return
            case nil, "pending": guard await changes.next() != nil else { throw HostedSessionError.notRunning }
            default: throw HostedSessionError.rejected(String(localized: "CuePad 的 MCP 服务连不上：\(status?.error ?? status?.status ?? "")"))
            }
        }
    }

    private func find(_ ref: String) throws -> OpenCodeModel {
        guard let key = AgentKind.opencode.modelKey(ref), let found = models.first(where: { $0.key == key }) else {
            throw HostedSessionError.rejected(String(localized: "OpenCode 没有模型 \(ref)"))
        }
        return found
    }

    private func open(_ create: Create, on client: OpenCodeClient) async throws -> String {
        let data = try await client.call("POST", "/api/session", directory: directory, body: create)
        return try JSONDecoder().decode(OpenCodeData<OpenCodeSessionInfo>.self, from: data).data.id
    }

    func newSession() async throws {
        guard let client, var create, let old = sessionID, let model else { throw HostedSessionError.notRunning }
        create.model = model.ref(level.flatMap(model.variant))
        sessionID = try await open(create, on: client)
        toolNames = [:]
        try await client.call("DELETE", "/api/session/\(old)")
    }

    func configure(model ref: String?, effort: PiThinkingLevel?) async throws {
        guard let client, let sessionID, let current = model else { throw HostedSessionError.notRunning }
        let target = try ref.map(find) ?? current
        let level = effort ?? level
        struct Switch: Encodable { var model: OpenCodeModelRef }
        try await client.call(
            "POST", "/api/session/\(sessionID)/model", directory: directory, body: Switch(model: target.ref(level.flatMap(target.variant))))
        model = target
        self.level = level
    }

    func send(_ text: String, images: [PiImage]) async throws {
        guard let client, let sessionID else { throw HostedSessionError.notRunning }
        struct File: Encodable { var uri: String }
        struct Prompt: Encodable { var text: String; var files: [File]; var delivery = "steer" }
        let files = images.map { File(uri: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())") }
        try await client.call("POST", "/api/session/\(sessionID)/prompt", directory: directory, body: Prompt(text: text, files: files))
    }

    /// 在不在跑由服务判断（歇着时是空操作）：刚交的话还没开出执行时也停得下。
    func abort() async throws {
        guard let client, let sessionID else { return }
        try await client.call("POST", "/api/session/\(sessionID)/interrupt", directory: directory)
    }

    /// 先删会话再关输入；删不掉的（服务已卡住或退出）留给下次起大脑时清。
    func stop() -> @concurrent @Sendable () async -> Void {
        let process = process, client = client, sessionID = sessionID
        self.client = nil
        self.sessionID = nil
        mcpChanges.continuation.finish()
        return {
            if let client, let sessionID {
                _ = try? await withDeadline(AgentTimeouts.end, orThrow: CancellationError()) {
                    try await client.call("DELETE", "/api/session/\(sessionID)")
                }
            }
            await process?.stop()
        }
    }

    private func received(_ event: OpenCodeEvent) {
        let data = event.data
        if event.type == "mcp.status.changed" { mcpChanges.continuation.yield() }
        guard let sessionID, data.sessionID == sessionID else { return }
        if let (_, draft) = drafts.apply(event) { session.emit(.speaking(draft)) }
        switch event.type {
        case "session.execution.started":
            toolNames = [:]
            session.emit(.turnStarted)
        case "session.step.ended":
            if let tokens = data.tokens { session.emit(.context(used: tokens.prompt, window: model?.limit?.context)) }
        case "session.tool.input.started":
            if let id = data.id, let name = data.name { toolNames[id] = name }
        case "session.tool.called":
            guard let id = data.id else { return }
            let name = toolNames[id] ?? "?"
            let arguments = String(decoding: (data.input?.json ?? [:]).data, as: UTF8.self)
            session.emit(.tool(id: id, name: CueMCPServer.bareName(name, on: .opencode), arguments: arguments))
        case "session.tool.success", "session.tool.failed":
            guard let id = data.id else { return }
            toolNames[id] = nil
            let failed = event.type == "session.tool.failed"
            session.emit(.toolDone(id: id, result: failed ? data.error?.message ?? "" : brainText(data.content), failed: failed))
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            if event.type == "session.execution.failed" {
                session.emit(.failed(data.error?.message ?? data.error?.type ?? OpenCodeRuntime.unknownFailure))
            }
            session.emit(.turnFinished)
        default:
            break
        }
    }
}
#endif

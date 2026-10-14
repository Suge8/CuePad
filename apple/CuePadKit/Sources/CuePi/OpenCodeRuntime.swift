#if os(macOS)
import CueStore
import Foundation
import OSLog

/// OpenCode 的接入：直连它的后台服务（事件流 + 接口），零安装。终端里的会话（OpenCode 的终端界面默认就连这个服务）与 CuePad 开的会话都在服务里；
/// 它的会话不在文件里，会话索引与对话由这里写进资料库（`agent` 为 `opencode`，路径是 `opencode:<会话 id>`）。
///
/// - 发现：读服务的登记文件（`AgentPaths.openCodeService`，校验属主与 0600），FSEvents 跟着它出现与消失，服务进程退出也算消失。
/// - 跟随：长连事件流；服务不续传，所以每次连上（含断线重连）都重拉一遍快照：会话列表、在跑的执行、在线会话待答的权限与表单。
/// - 在线：服务活着期间有过活动（建立、发话、执行、提问）的顶层会话在线——连上时按"最后修改晚于服务启动"认，之后按事件认；
///   没在跑就是歇着。服务停了、会话被删了下线；在 CuePad 里结束的会话也下线，直到它再有活动。子代理（子会话）不单独上线，
///   记在父会话的 `subagents` 里。一个服务承载全部会话，会话的 `pid` 是服务进程；服务端不知道终端的 tty，所以跳不到终端。
/// - 托管：服务没开时 `opencode service start` 把它拉起（常驻的后台进程，终端里的 OpenCode 也用它）；CuePad 拉起的那个在停止接入
///   （App 退出、关掉开关）时由 CuePad `opencode service stop`，本来就在跑的不动。
///   新会话显式带上工作目录建，接着已结束的会话就是对库里的会话接着说（同一个服务谁都能续）。
@MainActor
public final class OpenCodeRuntime: AgentRuntime {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "opencode")
    private static let sessionPage = 200
    /// 权限请求的三个选项（作答时按原文认）
    private static let allowOnce = "允许", allowAlways = "总是允许", reject = "拒绝"

    private let bridge: PiBridge
    private let paths: AgentPaths
    private let store: CueStore
    private let hostID: String
    private let locate: @Sendable () async -> ExecutableLocator
    private let transcriptWindow: TimeInterval

    private var watcher: FSEventsWatcher?
    private var watching: Task<Void, Never>?
    private var connection: Connection?
    private var waiters: [UUID: CheckedContinuation<Connection, any Error>] = [:]

    /// 这个服务上的顶层会话
    private var sessions: [String: Tracked] = [:]
    /// 子会话 → 父会话
    private var parents: [String: String] = [:]
    /// 子代理在跑的工具调用 → 名字
    private var childTools: [String: String] = [:]
    /// 在 CuePad 里结束的会话与结束时刻：再有活动才重新上线
    private var ended: [String: Date] = [:]
    /// 每个工作目录可选的模型与命令
    private var catalogs: [String: Catalog] = [:]
    /// 服务里全部顶层会话（会话索引对账用）；还没拉到完整列表时为 nil
    private var listed: Set<String>?
    private var checkpoints: [String: OpenCodeHistory.Checkpoint] = [:]
    private var ingestQueue: [String] = []
    private var ingesting: Task<Void, Never>?
    /// CuePad 拉起的服务（它的 `opencode` 与环境），停止接入时由 CuePad 停掉；本来就在跑的为 nil
    private var startedService: (executable: URL, environment: [String: String])?

    /// 连着的一个服务进程。
    @MainActor private final class Connection {
        let client: OpenCodeClient
        let startedAt: Date
        var exitWatcher: ProcessExitWatcher?
        var events: Task<Void, Never>?
        var ready = false
        var pid: Int32 { client.service.pid }

        init(client: OpenCodeClient, startedAt: Date) {
            self.client = client
            self.startedAt = startedAt
        }
    }

    private struct Catalog {
        var models: [OpenCodeModel]
        var commands: [PiSlashCommand]
    }

    /// 一个顶层会话此刻的样子（由快照与事件推出），发布时换成桥上的 `PiSession`。
    private struct Tracked {
        var info: OpenCodeSessionInfo
        var online = false
        var hosted = false
        var launchToken: String?
        /// 状态、要你回答的、子代理（子会话按会话 id）
        var facts = SessionFacts()
        /// 在跑的工具调用 → 名字（`tool.called` 不带名字，名字在它之前的 `tool.input.started` 里）
        var toolNames: [String: String] = [:]
        var tokens: Int?
        var firstMessage: String?

        var directory: String { info.location.directory }
    }

    public init(
        bridge: PiBridge, paths: AgentPaths, store: CueStore, hostID: String,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        transcriptWindow: TimeInterval = .infinity
    ) {
        self.bridge = bridge
        self.paths = paths
        self.store = store
        self.hostID = hostID
        self.locate = locate
        self.transcriptWindow = transcriptWindow
    }

    // MARK: 发现

    public func start() throws {
        let watcher = FSEventsWatcher(root: paths.openCodeService.deletingLastPathComponent())
        self.watcher = watcher
        watching = Task { [weak self] in
            for await _ in watcher.paths { self?.refresh() }
        }
        refresh()
    }

    /// 停下后可再 `start()`（接入开关关了又开）：会话下桥，读到哪的缓存一并丢掉——索引随断开接入删了，再接入从头读。
    public func stop() -> @concurrent @Sendable () async -> Void {
        watching?.cancel()
        watcher?.stop()
        watcher = nil
        disconnect()
        checkpoints = [:]
        ingesting?.cancel()
        let ingesting = ingesting
        self.ingesting = nil
        let stopService = stopStartedService()
        return {
            await ingesting?.value
            await stopService()
        }
    }

    /// 停掉 CuePad 拉起的服务（`opencode service stop`，它删掉登记文件，会话随之下线）；本来就在跑的不动。
    public func stopStartedService() -> @concurrent @Sendable () async -> Void {
        guard let service = startedService else { return {} }
        startedService = nil
        return { _ = await ChildProcess.run(service.executable, ["service", "stop"], environment: service.environment, timeout: AgentTimeouts.end) }
    }

    /// 登记文件变了：换了服务就断开旧的、连上新的，没了就断开。
    private func refresh() {
        let info = OpenCodeServiceInfo.read(paths.openCodeService)
        guard info != connection?.client.service else { return }
        if connection != nil { disconnect() }
        guard let info, let startedAt = info.startedAt else { return }
        let connection = Connection(client: OpenCodeClient(info), startedAt: startedAt)
        self.connection = connection
        connection.exitWatcher = ProcessExitWatcher(pid: info.pid) { [weak self] in
            if self?.connection?.client.service == info { self?.disconnect() }
        }
        connection.events = Task { [weak self] in await self?.follow(connection) }
    }

    private func close(_ connection: Connection) {
        connection.events?.cancel()
        connection.exitWatcher?.cancel()
    }

    /// 服务停了：它的会话全部下线。
    private func disconnect() {
        guard let connection else { return }
        close(connection)
        self.connection = nil
        for (id, tracked) in sessions where tracked.online { bridge.detach(bridgeID(id, connection), reason: .disconnected) }
        sessions = [:]
        parents = [:]
        childTools = [:]
        ended = [:]
        catalogs = [:]
        listed = nil
        ingestQueue = []
    }

    /// 跟着事件流，直到服务停了（进程退出、登记文件没了或换了，任务随连接一起取消）：每次连上都重拉快照；断了、连不上或快照失败就隔一会儿重连。
    /// 服务"又能连了"没有事件可等，所以按退避重试：间隔从 1 秒翻倍到 30 秒，连上并拉完快照后复位。
    private func follow(_ connection: Connection) async {
        var delay = Self.retryFloor
        while !Task.isCancelled, self.connection === connection {
            do {
                for try await event in connection.client.events() {
                    guard self.connection === connection else { return }
                    if event.type == "server.connected" {
                        try await snapshot(connection)
                        delay = Self.retryFloor
                    } else {
                        await apply(event, connection)
                    }
                }
            } catch {
                Self.log.error("OpenCode 事件流断开或快照失败，\(delay, privacy: .public) 后重连：\(String(describing: error), privacy: .public)")
            }
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            delay = min(delay * 2, Self.retryCeiling)
        }
    }

    private static let retryFloor: Duration = .seconds(1)
    private static let retryCeiling: Duration = .seconds(30)

    // MARK: 快照

    private func snapshot(_ connection: Connection) async throws {
        let client = connection.client
        var all: [OpenCodeSessionInfo] = []
        var cursor: String?
        repeat {
            let query = "limit=\(Self.sessionPage)" + (cursor.map { "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? "")
            let page = try await client.get(OpenCodePage<OpenCodeSessionInfo>.self, "/api/session?\(query)")
            all += page.data
            cursor = page.data.isEmpty ? nil : page.cursor?.next
        } while cursor != nil
        let active = Set(try await client.get(OpenCodeData<[String: OpenCodeActive]>.self, "/api/session/active").data.keys)
        guard self.connection === connection else { return }

        let topLevel = all.filter { $0.parentID == nil }
        for info in topLevel {
            var tracked = sessions[info.id] ?? Tracked(info: info)
            tracked.info = info
            // 断线期间错过的事件不补：执行与压缩的进展只认此刻的快照（在线会话的压缩中与出错原文由 refreshLive 补上）
            tracked.facts.running = active.contains(info.id)
            tracked.facts.work(.thinking)
            tracked.toolNames = [:]
            tracked.facts.compacting = false
            tracked.facts.failure = !tracked.facts.running && info.outcome == "failed" ? Self.unknownFailure : nil
            if tracked.facts.running || info.updatedAt >= connection.startedAt, ended[info.id].map({ info.updatedAt > $0 }) ?? true {
                tracked.online = true
            }
            sessions[info.id] = tracked
        }
        let present = Set(topLevel.map(\.id))
        for (id, tracked) in sessions where !present.contains(id) {
            if tracked.online { bridge.detach(bridgeID(id, connection), reason: .closed(reason: "deleted")) }
            sessions[id] = nil
        }
        for child in all where child.parentID != nil && child.updatedAt >= connection.startedAt {
            guard let parent = child.parentID, sessions[parent] != nil else { continue }
            parents[child.id] = parent
            let phase: PiSubagentPhase = if active.contains(child.id) { .running } else {
                switch child.outcome {
                case "failed": .failed
                case "interrupted": .interrupted
                default: .done
                }
            }
            subagent(child.id, of: parent) { agent in
                agent.phase = .known(phase)
                agent.startedAt = child.createdAt
                agent.settledAt = phase == .running ? nil : child.updatedAt
                agent.name = child.title ?? ""
                agent.role = child.agent ?? ""
            }
        }
        for (id, tracked) in sessions where tracked.online { try await refreshLive(id, tracked, client) }
        guard self.connection === connection else { return }
        for (id, tracked) in sessions where tracked.online && tracked.firstMessage == nil {
            sessions[id]?.firstMessage = try await checkpoint(of: id)?.history.firstMessage
        }
        guard self.connection === connection else { return }
        listed = present
        connection.ready = true
        for (id, tracked) in sessions where tracked.online { publish(id) }
        for waiter in waiters.values { waiter.resume(returning: connection) }
        waiters = [:]
        Task { await backfill(topLevel, connection) }
    }

    /// 在线会话此刻要的另几样：待答的权限与表单、上下文用量、工作目录的模型与命令。
    private func refreshLive(_ id: String, _ tracked: Tracked, _ client: OpenCodeClient) async throws {
        var permissions: [OpenCodePermission] = [], forms: [OpenCodeForm] = []
        let running = tracked.facts.subagents.filter { $0.state.phase == .known(.running) }.map(\.id)
        for asker in [id] + running {
            permissions += try await client.get(OpenCodeData<[OpenCodePermission]>.self, "/api/session/\(asker)/permission").data
            forms += try await client.get(OpenCodeData<[OpenCodeForm]>.self, "/api/session/\(asker)/form").data
        }
        let last = try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(id)/message?type=assistant&limit=1").data.first
        // 压缩开始与结束之间，最近一条压缩消息是 running：断线时错过了开始事件，从它恢复"压缩中"
        let compaction = try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(id)/message?type=compaction&limit=1").data.first
        try await catalog(tracked.directory, client)
        sessions[id]?.facts.questions = permissions.map(Self.question) + forms.map(Self.question)
        sessions[id]?.tokens = last?.tokens?.context
        sessions[id]?.facts.compacting = compaction?.status == "running"
        if tracked.info.model == nil { sessions[id]?.info.model = last?.model }
        if tracked.facts.failure != nil, let error = last?.error?.message { sessions[id]?.facts.failure = error }
    }

    /// 工作目录的模型与命令（没取过才取）。
    @discardableResult
    private func catalog(_ directory: String, _ client: OpenCodeClient, reload: Bool = false) async throws -> Catalog {
        if !reload, let catalog = catalogs[directory] { return catalog }
        let models = try await client.get(OpenCodeData<[OpenCodeModel]>.self, "/api/model", directory: directory).data
        let commands = try await client.get(OpenCodeData<[OpenCodeCommand]>.self, "/api/command", directory: directory).data
        let catalog = Catalog(
            models: models,
            commands: [PiSlashCommand(name: Self.compact, summary: "压缩上下文", source: .known(.builtin))]
                + commands.map { PiSlashCommand(name: $0.name, summary: $0.description.map { String($0.prefix(120)) }, source: .known(.prompt)) })
        catalogs[directory] = catalog
        return catalog
    }

    private static let compact = "compact"
    private static let unknownFailure = "出错了"

    // MARK: 事件

    private func apply(_ event: OpenCodeEvent, _ connection: Connection) async {
        let data = event.data
        switch event.type {
        case "model.updated", "command.updated":
            guard let directory = event.location?.directory, catalogs[directory] != nil else { return }
            _ = try? await catalog(directory, connection.client, reload: true)
            for (id, tracked) in sessions where tracked.directory == directory { publish(id) }
            return
        // 子代理要你确认的也挂在顶层会话上（它在等，整个会话就在等）；作答时按标识里记的会话答
        case "permission.asked":
            guard let sessionID = data.sessionID, let id = data.id else { return }
            let question = Self.question(OpenCodePermission(id: id, sessionID: sessionID, action: data.action ?? "", resources: data.resources ?? []))
            await change(topLevel(sessionID), connection, active: true) { $0.facts.questions.append(question) }
            return
        case "permission.replied":
            guard let sessionID = data.sessionID, let id = data.requestID else { return }
            await change(topLevel(sessionID), connection) { $0.facts.questions.removeAll { $0.promptID == Self.prompt(.permission, sessionID, id) } }
            return
        case "form.created":
            guard let form = data.form else { return }
            await change(topLevel(form.sessionID), connection, active: true) { $0.facts.questions.append(Self.question(form)) }
            return
        case "form.replied", "form.cancelled":
            guard let sessionID = data.sessionID, let id = data.id else { return }
            await change(topLevel(sessionID), connection) { $0.facts.questions.removeAll { $0.promptID == Self.prompt(.form, sessionID, id) } }
            return
        default: break
        }
        guard event.type.hasPrefix("session."), let sessionID = data.sessionID else { return }
        if let parent = data.parentID ?? parents[sessionID] {
            child(sessionID, of: parent, event)
            return
        }
        switch event.type {
        case "session.created":
            guard let location = data.location else { return }
            let now = Date().timeIntervalSince1970 * 1000
            let info = OpenCodeSessionInfo(
                id: sessionID, title: data.title, agent: data.agent, model: data.model, location: location, time: .init(created: now, updated: now))
            if sessions[sessionID] == nil { sessions[sessionID] = Tracked(info: info) }
            listed?.insert(sessionID)
            await change(sessionID, connection, active: true) { _ in }
        case "session.deleted":
            guard let tracked = sessions.removeValue(forKey: sessionID) else { return }
            if tracked.online { bridge.detach(bridgeID(sessionID, connection), reason: .closed(reason: "deleted")) }
            listed?.remove(sessionID)
            await retainIndex()
        case "session.renamed":
            await change(sessionID, connection) { $0.info.title = data.title }
        case "session.model.selected":
            await change(sessionID, connection) { $0.info.model = data.model }
        case "session.inbox.enqueued":
            await change(sessionID, connection, active: true) {
                if $0.firstMessage == nil { $0.firstMessage = data.item?.payload?.text.map { String($0.prefix(PiSessionName.firstMessageLimit)) } }
            }
        case "session.inbox.delivered":
            enqueueIngest(sessionID, urgent: true)
        case "session.execution.started":
            await change(sessionID, connection, active: true) { $0.facts.startTurn() }
        case "session.step.started":
            // 没给会话选过模型时它用配置里的默认模型：每一步都带着实际用的那个
            await change(sessionID, connection) {
                $0.facts.work(.thinking)
                if let model = data.model { $0.info.model = model }
            }
        case "session.reasoning.started":
            await change(sessionID, connection) { $0.facts.work(.thinking) }
        case "session.text.started":
            await change(sessionID, connection) { $0.facts.work(.outputting) }
        case "session.tool.input.started":
            guard let id = data.id, let name = data.name else { return }
            await change(sessionID, connection) { $0.toolNames[id] = name }
        case "session.tool.called":
            guard let id = data.id else { return }
            await change(sessionID, connection) { $0.facts.work(.tool, detail: ToolDetail.line($0.toolNames[id] ?? "tool", data.input?.arguments)) }
        case "session.tool.success", "session.tool.failed":
            await change(sessionID, connection) {
                if let id = data.id { $0.toolNames[id] = nil }
                if $0.toolNames.isEmpty { $0.facts.work(.thinking) }
            }
        case "session.step.ended":
            await change(sessionID, connection) { if let tokens = data.tokens { $0.tokens = tokens.context } }
            enqueueIngest(sessionID, urgent: true)
        case "session.compaction.started":
            await change(sessionID, connection, active: true) { $0.facts.compacting = true }
        case "session.compaction.ended", "session.compaction.failed":
            await change(sessionID, connection) {
                $0.facts.compacting = false
                if event.type == "session.compaction.ended" { $0.tokens = nil }
            }
            enqueueIngest(sessionID, urgent: true)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            await change(sessionID, connection) {
                $0.toolNames = [:]
                let failure = event.type == "session.execution.failed" ? (data.error?.message ?? data.error?.type ?? Self.unknownFailure) : nil
                let questions = $0.facts.questions
                $0.facts.endTurn(failure: failure)
                $0.facts.questions = questions  // 权限与表单随它们自己的事件收起
            }
            enqueueIngest(sessionID, urgent: true)
        default:
            break
        }
    }

    /// 改一个顶层会话并发布。`active`：这是一次活动，会话不在线就上线（在 CuePad 里结束过的也重新上线）。
    /// 不认识的会话（连上之后才建、事件先于列表）先取它的信息。
    private func change(_ sessionID: String, _ connection: Connection, active: Bool = false, _ body: (inout Tracked) -> Void) async {
        if sessions[sessionID] == nil {
            guard active, let info = try? await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(sessionID)").data,
                  info.parentID == nil, self.connection === connection else { return }
            sessions[sessionID] = sessions[sessionID] ?? Tracked(info: info)
        }
        guard var tracked = sessions[sessionID] else { return }
        body(&tracked)
        if active, !tracked.online {
            tracked.online = true
            ended[sessionID] = nil
        }
        sessions[sessionID] = tracked
        if tracked.online, catalogs[tracked.directory] == nil { _ = try? await catalog(tracked.directory, connection.client) }
        publish(sessionID)
    }

    /// 子会话的事件落到父会话的子代理名册上。
    private func child(_ sessionID: String, of parent: String, _ event: OpenCodeEvent) {
        parents[sessionID] = parent
        let data = event.data
        let now = Date()
        subagent(sessionID, of: parent) { agent in
            switch event.type {
            case "session.created":
                agent.name = data.title ?? ""
                agent.role = data.agent ?? ""
                agent.startedAt = now
            case "session.execution.started":
                agent.phase = .known(.running)
                agent.settledAt = nil
            case "session.tool.input.started":
                if let id = data.id, let name = data.name { childTools[id] = name }
            case "session.tool.called":
                agent.action = ToolDetail.line(data.id.flatMap { childTools.removeValue(forKey: $0) } ?? "tool", data.input?.arguments)
            case "session.execution.succeeded":
                agent.phase = .known(.done)
                agent.action = ""
                agent.settledAt = now
            case "session.execution.failed":
                agent.phase = .known(.failed)
                agent.action = data.error?.message ?? ""
                agent.settledAt = now
            case "session.execution.interrupted":
                agent.phase = .known(.interrupted)
                agent.action = ""
                agent.settledAt = now
            default: break
            }
        }
        publish(parent)
    }

    private func subagent(_ id: String, of parent: String, _ body: (inout PiSubagentState) -> Void) {
        guard var tracked = sessions[parent] else { return }
        if !tracked.facts.subagents.contains(where: { $0.id == id }) { tracked.facts.startSubagent(id, name: "", role: "", at: Date()) }
        tracked.facts.updateSubagent(id, body)
        sessions[parent] = tracked
    }

    // MARK: 发布到桥

    private func bridgeID(_ sessionID: String, _ connection: Connection) -> PiSession.ID { "\(sessionID).\(connection.pid)" }

    /// 把一个会话此刻的样子交给桥：在线的上桥或更新，不在线的不动（下线由调用方 `detach`）。
    private func publish(_ sessionID: String) {
        guard let connection, connection.ready, var tracked = sessions[sessionID], tracked.online else { return }
        let id = bridgeID(sessionID, connection)
        let catalog = catalogs[tracked.directory]
        let model = tracked.info.model.map { ref in
            catalog?.models.first { $0.key == PiModelKey(provider: ref.providerID, id: ref.id) }?.option
                ?? PiModelOption(key: PiModelKey(provider: ref.providerID, id: ref.id), name: ref.id, thinkingLevels: [.off])
        }
        let window = tracked.info.model.flatMap { ref in catalog?.models.first { $0.id == ref.id && $0.providerID == ref.providerID }?.limit?.context }
        func fill(_ session: inout PiSession) {
            tracked.facts.publish(to: &session)
            session.name = tracked.info.title
            session.firstMessage = tracked.firstMessage
            session.launchToken = tracked.launchToken
            session.hosted = tracked.hosted
            session.model = model
            session.thinking = model.flatMap { Self.thinking(tracked.info.model?.variant, of: $0) }
            session.availableModels = catalog?.models.map(\.option) ?? []
            session.context = window.map { PiContextUsage(tokens: tracked.tokens, window: $0) }
            session.commands = catalog?.commands ?? []
        }
        if bridge.session(id: id) == nil {
            var session = PiSession(
                id: id, sessionID: sessionID, agent: .opencode, sessionFile: nil, pid: connection.pid,
                cwd: URL(filePath: tracked.directory, directoryHint: .isDirectory), terminal: PiTerminal(), extensionVersion: 0,
                state: .settled, stateSince: .now)
            fill(&session)
            bridge.attach(session, via: OpenCodeLink(runtime: self, sessionID: sessionID))
        } else {
            bridge.update(id, fill)
        }
        sessions[sessionID] = tracked
    }

    /// 强度是模型的 `variant`；没设（`default`）时，没有强度可选的模型是 `off`，有的不知道是哪一档。
    private static func thinking(_ variant: String?, of model: PiModelOption) -> Open<PiThinkingLevel>? {
        guard let variant, variant != "default" else { return model.thinkingLevels == [.off] ? .known(.off) : nil }
        return Open(rawValue: variant)
    }

    // MARK: 问答

    private func topLevel(_ sessionID: String) -> String { parents[sessionID] ?? sessionID }

    /// 弹窗的标识：种类、提问的会话（可能是子代理）、它的请求 id。
    private enum PromptKind: String { case permission, form }

    private static func prompt(_ kind: PromptKind, _ sessionID: String, _ id: String) -> String { "\(kind.rawValue):\(sessionID)/\(id)" }

    private static func parse(_ promptID: String) -> (kind: PromptKind, sessionID: String, id: String)? {
        let parts = promptID.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let kind = PromptKind(rawValue: String(parts[0])) else { return nil }
        let rest = parts[1].split(separator: "/", maxSplits: 1)
        guard rest.count == 2 else { return nil }
        return (kind, String(rest[0]), String(rest[1]))
    }

    private static func question(_ permission: OpenCodePermission) -> PiQuestion {
        let text = PermissionWording.question(.opencode, "使用 \(permission.action)", permission.resources)
        return PiQuestion(
            promptID: prompt(.permission, permission.sessionID, permission.id), kind: .select, text: text,
            options: [allowOnce, allowAlways, reject])
    }

    /// 只有一个字段的表单能从 CuePad 答（`question` 工具问一个问题时就是这样）：有选项的是选择，文字是填空，是否是确认；其余只能在 OpenCode 里答。
    private static func question(_ form: OpenCodeForm) -> PiQuestion {
        guard form.fields.count == 1, let field = form.fields.first else {
            return PiQuestion(promptID: nil, kind: .unknown("form"), text: String((form.title ?? "").prefix(500)))
        }
        let text = String([field.title, field.description].compactMap { $0 }.joined(separator: "\n").prefix(500))
        switch field.type {
        case "string" where field.options?.isEmpty == false:
            return PiQuestion(
                promptID: prompt(.form, form.sessionID, form.id), kind: .select, text: text, options: field.options!.map(\.label),
                allowsOther: field.custom == true)
        case "string": return PiQuestion(promptID: prompt(.form, form.sessionID, form.id), kind: .text, text: text)
        case "boolean": return PiQuestion(promptID: prompt(.form, form.sessionID, form.id), kind: .confirm, text: text)
        default: return PiQuestion(promptID: nil, kind: .unknown(field.type), text: text)
        }
    }

    // MARK: 控制（经 `OpenCodeLink`）

    private func live(_ sessionID: String) throws -> (Connection, Tracked) {
        guard let connection, connection.ready, let tracked = sessions[sessionID], tracked.online else { throw PiBridgeError.sessionEnded }
        return (connection, tracked)
    }

    fileprivate func send(_ message: PiMessage, to sessionID: String) async throws -> PiDelivery {
        let (connection, tracked) = try live(sessionID)
        struct File: Encodable { var uri: String }
        struct Metadata: Encodable { var cuepadDelivery: String }
        struct Prompt: Encodable { var text: String; var files: [File]; var metadata: Metadata?; var delivery: String }
        let busy = tracked.facts.running || tracked.facts.compacting
        let mode = message.whenBusy ?? .followUp
        let prompt = Prompt(
            text: message.text, files: message.images.map { File(uri: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())") },
            metadata: message.deliveryID.map(Metadata.init), delivery: mode == .steer ? "steer" : "queue")
        try await connection.client.call("POST", "/api/session/\(sessionID)/prompt", body: prompt)
        return busy ? .queued(mode) : .immediate
    }

    fileprivate func command(_ line: String, whenBusy: PiQueueMode?, in sessionID: String) async throws {
        let (connection, tracked) = try live(sessionID)
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? ""
        let arguments = parts.count > 1 ? String(parts[1]) : ""
        let delivery = whenBusy == .steer ? "steer" : "queue"
        if name == Self.compact {
            struct Compact: Encodable { var delivery: String }
            try await connection.client.call("POST", "/api/session/\(sessionID)/compact", body: Compact(delivery: delivery))
            return
        }
        guard try await catalog(tracked.directory, connection.client).commands.contains(where: { $0.name == name }) else {
            throw PiBridgeError.rejected("unknown_command")
        }
        struct Command: Encodable { var name: String; var text: String; var delivery: String }
        do {
            try await connection.client.call(
                "POST", "/api/session/\(sessionID)/command", body: Command(name: name, text: arguments, delivery: delivery))
        } catch let error as OpenCodeAPIError {
            throw PiBridgeError.rejected(error.tag == "CommandNotFoundError" ? "unknown_command" : "failed: \(error.message)")
        }
    }

    fileprivate func abort(_ sessionID: String) async throws {
        let (connection, _) = try live(sessionID)
        try await connection.client.call("POST", "/api/session/\(sessionID)/interrupt")
    }

    fileprivate func answer(_ answer: PiAnswerValue, to promptID: String, in sessionID: String) async throws {
        let (connection, tracked) = try live(sessionID)
        guard let question = tracked.facts.questions.first(where: { $0.promptID == promptID }), let target = Self.parse(promptID) else {
            throw PiBridgeError.rejected("stale_prompt")
        }
        if target.kind == .permission {
            let decision: String
            switch answer {
            case .option(Self.allowOnce), .confirmed(true): decision = "once"
            case .option(Self.allowAlways): decision = "always"
            case .option(Self.reject), .confirmed(false): decision = "reject"
            default: throw PiBridgeError.rejected("bad_answer")
            }
            struct Reply: Encodable { var decision: String }
            try await connection.client.call(
                "POST", "/api/session/\(target.sessionID)/permission/\(target.id)/reply", body: Reply(decision: decision))
            return
        }
        let forms = try await connection.client.get(OpenCodeData<[OpenCodeForm]>.self, "/api/session/\(target.sessionID)/form").data
        guard let field = forms.first(where: { $0.id == target.id })?.fields.first else { throw PiBridgeError.rejected("stale_prompt") }
        let value: OpenCodeAnswer
        switch (question.kind.known, answer) {
        case (.select, .option(let label)):
            guard let option = field.options?.first(where: { $0.label == label }) else { throw PiBridgeError.rejected("bad_answer") }
            value = .string(option.value)
        case (.text, .text(let text)), (.select, .text(let text)) where question.acceptsText: value = .string(text)
        case (.confirm, .confirmed(let yes)): value = .bool(yes)
        default: throw PiBridgeError.rejected("bad_answer")
        }
        struct Reply: Encodable { var answer: [String: OpenCodeAnswer] }
        try await connection.client.call("POST", "/api/session/\(target.sessionID)/form/\(target.id)/reply", body: Reply(answer: [field.key: value]))
    }

    fileprivate func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in sessionID: String) async throws {
        let (connection, tracked) = try live(sessionID)
        if let name {
            struct Update: Encodable { var title: String }
            try await connection.client.call("PATCH", "/api/session/\(sessionID)", body: Update(title: name))
        }
        if model != nil || thinking != nil {
            let current = tracked.info.model
            guard let key = model ?? current.map({ PiModelKey(provider: $0.providerID, id: $0.id) }) else { throw PiBridgeError.unknownModel(.opencode) }
            // 服务刚起时头一次取到的模型表是空的（实测 2.0.25：约 0.2 秒后才有），开会话紧接着配模型就会撞上：没找到先重取一次再说
            var target = try await catalog(tracked.directory, connection.client).models.first { $0.key == key }
            if target == nil { target = try await catalog(tracked.directory, connection.client, reload: true).models.first { $0.key == key } }
            guard let target else { throw PiBridgeError.unknownModel(.opencode) }
            let variants = (target.variants ?? []).map(\.id)
            // 模型没有强度档（没有 variant）时不带；关闭就是不带 variant
            let level = thinking.flatMap { target.thinkingLevels.isEmpty ? nil : $0.clamped(to: target.thinkingLevels) }
            let variant: String? = if thinking != nil { level == .off ? nil : level?.rawValue }
                else { current?.variant.flatMap { variants.contains($0) ? $0 : nil } }
            let ref = OpenCodeModelRef(id: target.id, providerID: target.providerID, variant: variant)
            struct Switch: Encodable { var model: OpenCodeModelRef }
            try await connection.client.call("POST", "/api/session/\(sessionID)/model", body: Switch(model: ref))
        }
        // 桥上的名字与模型只随服务自己的事件（改名、选模型）更新，不在这里先写
    }

    /// 结束：停下在跑的一轮，会话下线（它还在服务里，再有活动——终端里接着说、CuePad 接着它——就重新上线）。
    fileprivate func endSession(_ sessionID: String) async throws {
        let (connection, tracked) = try live(sessionID)
        if tracked.facts.running || tracked.facts.compacting { try await connection.client.call("POST", "/api/session/\(sessionID)/interrupt") }
        guard self.connection === connection, sessions[sessionID]?.online == true else { return }
        sessions[sessionID]?.online = false
        ended[sessionID] = Date()
        bridge.detach(bridgeID(sessionID, connection), reason: .closed(reason: "quit"))
    }

    // MARK: 托管

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let connection = try await ensureService()
        struct Create: Encodable { var location: OpenCodeLocation }
        let data = try await connection.client.call(
            "POST", "/api/session", body: Create(location: OpenCodeLocation(directory: directory.path(percentEncoded: false))))
        let info = try JSONDecoder().decode(OpenCodeData<OpenCodeSessionInfo>.self, from: data).data
        let id = try await host(info, connection) {
            $0.hosted = true
            $0.launchToken = launchToken
        }
        let sessionID = info.id
        do {
            return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
        } catch {
            // 配不上时结束只让它下线，会话还在服务里：开会话失败的不留，从服务里删掉
            _ = try? await connection.client.call("DELETE", "/api/session/\(sessionID)")
            throw error
        }
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        let connection = try await ensureService()
        let online = sessions[session.id]?.online == true
        let info: OpenCodeSessionInfo
        do {
            info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(session.id)").data
        } catch let error as OpenCodeAPIError where error.status == 404 {
            throw PiBridgeError.unknownSession(session.id)
        }
        return try await host(info, connection) { if !online { $0.hosted = true } }
    }

    /// 让 CuePad 托管的会话上线；已经在线的（比如终端里正开着）不算托管。
    private func host(_ info: OpenCodeSessionInfo, _ connection: Connection, _ body: (inout Tracked) -> Void) async throws -> PiSession.ID {
        guard self.connection === connection else { throw PiBridgeError.sessionEnded }
        var tracked = sessions[info.id] ?? Tracked(info: info)
        tracked.online = true
        ended[info.id] = nil
        body(&tracked)
        sessions[info.id] = tracked
        listed?.insert(info.id)
        try await catalog(info.location.directory, connection.client)
        publish(info.id)
        return bridgeID(info.id, connection)
    }

    /// 连着的服务；没开就把它拉起来，等连上、拉完快照。
    private func ensureService() async throws -> Connection {
        if connection == nil {
            try await launchService()
            refresh()
        }
        // 起服务期间登记文件的变化可能已经让它连上、拉完快照
        if let connection, connection.ready { return connection }
        let id = UUID()
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: AgentTimeouts.launch)) != nil else { return }
            self?.waiters.removeValue(forKey: id)?.resume(throwing: AgentRuntimeError.launchTimedOut(.opencode))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    /// `opencode service start`：起后台服务、写好登记文件才返回（实测约 0.2 秒）。服务自成一个会话（不在这条命令的进程组里，
    /// 超时结束整组碰不到它），标准输入输出指到 /dev/null（不握着这边的管道）：实测 2.0.25。
    private func launchService() async throws {
        let locator = await locate()
        guard let executable = locator.executable(.opencode) else { throw AgentRuntimeError.notInstalled(.opencode) }
        // 服务常驻，它起的工具也用这个 PATH
        let environment = locator.environment(launching: executable, overrides: paths.environment)
        guard let result = await ChildProcess.run(executable, ["service", "start"], environment: environment, timeout: AgentTimeouts.launch, collect: false)
        else { throw AgentRuntimeError.launchTimedOut(.opencode) }
        guard result.status == 0 else { throw AgentRuntimeError.launchFailed(.opencode, "opencode service start 退出码 \(result.status)") }
        startedService = (executable, environment)
    }

    // MARK: 会话索引与对话

    private static func path(_ sessionID: String) -> String { "opencode:\(sessionID)" }

    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> PiTranscript {
        let connection = try await ensureService()
        let info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(session.id)").data
        return try await OpenCodeHistory.read(connection.client, info, from: nil, files: files).transcript
    }

    /// 连上后对一遍索引：变了的会话里，`transcriptWindow` 内活动过的读对话，更早的只写摘要；服务里没有了的删掉。
    private func backfill(_ infos: [OpenCodeSessionInfo], _ connection: Connection) async {
        do {
            let stored = Dictionary(
                try await store.piSessions().filter { $0.agent == .opencode }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard self.connection === connection else { return }  // 读的时候停下了（断开接入）：索引已删，不再写回
            var summaries: [PiSessionUpsert] = []
            let recent = Date().addingTimeInterval(-transcriptWindow)
            for info in infos {
                if let indexed = stored[info.id], abs(indexed.lastActivityAt.timeIntervalSince(info.updatedAt)) < 0.001 { continue }
                if info.updatedAt > recent {
                    enqueueIngest(info.id, urgent: false)
                } else {
                    summaries.append(PiSessionUpsert(session: indexed(info, firstMessage: nil), checkpoint: nil, transcript: nil))
                }
            }
            if !summaries.isEmpty { try await store.upsertPiSessions(summaries, host: hostID) }
            guard self.connection === connection else { return }
            await retainIndex()
        } catch {
            Self.log.error("OpenCode 会话索引回填失败：\(String(describing: error), privacy: .public)")
        }
    }

    private func indexed(_ info: OpenCodeSessionInfo, firstMessage: String?) -> IndexedSession {
        IndexedSession(
            id: info.id, path: Self.path(info.id), cwd: info.location.directory,
            title: PiSessionName.display(name: info.title, firstMessage: firstMessage, folder: URL(filePath: info.location.directory).lastPathComponent),
            lastActivityAt: info.updatedAt, agent: .opencode)
    }

    /// 只留服务里还有的会话的索引（只在拉到过完整列表之后）。
    private func retainIndex() async {
        guard let listed else { return }
        do {
            try await store.retainPiSessions(paths: Set(listed.map(Self.path)), agent: .opencode, host: hostID)
        } catch {
            Self.log.error("OpenCode 会话索引对账失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 排队读一个会话的新消息（同一会话不并发读；在线会话的排到前面）。
    private func enqueueIngest(_ sessionID: String, urgent: Bool) {
        guard sessions[sessionID] != nil || !urgent else { return }
        if let index = ingestQueue.firstIndex(of: sessionID) {
            guard urgent else { return }
            ingestQueue.remove(at: index)
        }
        if urgent { ingestQueue.insert(sessionID, at: 0) } else { ingestQueue.append(sessionID) }
        guard ingesting == nil else { return }
        ingesting = Task { [weak self] in
            while let self, !Task.isCancelled, !self.ingestQueue.isEmpty {
                let next = self.ingestQueue.removeFirst()
                await self.ingest(next)
            }
            if !Task.isCancelled { self?.ingesting = nil }  // 取消的是被 stop 换下的，不清掉新起的
        }
    }

    /// 读到哪了（含首条消息）：这次连上读过的在内存里，之前的在资料库里。
    private func checkpoint(of sessionID: String) async throws -> OpenCodeHistory.Checkpoint? {
        if let checkpoint = checkpoints[sessionID] { return checkpoint }
        return try await store.piCheckpoint(of: sessionID).flatMap { try? JSONDecoder().decode(OpenCodeHistory.Checkpoint.self, from: $0) }
    }

    private func ingest(_ sessionID: String) async {
        guard let connection else { return }
        do {
            let info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(sessionID)").data
            guard info.parentID == nil else { return }
            let (next, transcript) = try await OpenCodeHistory.read(connection.client, info, from: try await checkpoint(of: sessionID), files: store.files)
            // 读的时候会话被删了：删除时已对过账，这里再写就把索引写回来了
            guard self.connection === connection, sessions[sessionID] != nil else { return }
            checkpoints[sessionID] = next
            try await store.upsertPiSessions(
                [PiSessionUpsert(
                    session: indexed(info, firstMessage: next.history.firstMessage), checkpoint: try JSONEncoder().encode(next),
                    transcript: transcript)],
                host: hostID)
            if self.connection === connection, sessions[sessionID]?.firstMessage == nil, let first = next.history.firstMessage {
                sessions[sessionID]?.firstMessage = first
                publish(sessionID)
            }
        } catch let error as OpenCodeAPIError where error.status == 404 {
            return  // 读的时候会话被删了：删除事件会对账
        } catch {
            Self.log.error("读 OpenCode 会话 \(sessionID, privacy: .public) 的对话失败：\(String(describing: error), privacy: .public)")
        }
    }
}

/// `GET /api/session/active` 的一项（只有 `running`）。
struct OpenCodeActive: Decodable, Sendable { var type: String }

/// 表单答案的一个值。
enum OpenCodeAnswer: Encodable {
    case string(String), bool(Bool)
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// 一个 OpenCode 会话的控制通道：命令交给接入，经服务的接口做。没有"重新载入"（同一个服务里没有第二份会话）。
@MainActor
final class OpenCodeLink: SessionLink {
    private weak var runtime: OpenCodeRuntime?
    private let sessionID: String

    init(runtime: OpenCodeRuntime, sessionID: String) {
        self.runtime = runtime
        self.sessionID = sessionID
    }

    private func use() throws -> OpenCodeRuntime {
        guard let runtime else { throw PiBridgeError.sessionEnded }
        return runtime
    }

    func send(_ message: PiMessage) async throws -> PiDelivery { try await use().send(message, to: sessionID) }
    func command(_ line: String, whenBusy: PiQueueMode?) async throws { try await use().command(line, whenBusy: whenBusy, in: sessionID) }
    func end() async throws { try await use().endSession(sessionID) }
    func abort() async throws { try await use().abort(sessionID) }
    func answer(_ answer: PiAnswerValue, to promptID: String) async throws { try await use().answer(answer, to: promptID, in: sessionID) }
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        try await use().configure(model: model, thinking: thinking, name: name, in: sessionID)
    }
}
#endif

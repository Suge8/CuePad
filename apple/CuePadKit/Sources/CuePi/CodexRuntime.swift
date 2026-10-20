#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

/// Codex 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它常驻服务的控制 socket 说话；后台托管的会话是 CuePad 起的 `codex app-server`。
///
/// - 状态来自钩子：提交一句话进入工作，调工具、等权限确认、压缩随事件更新，`Stop`/`Interrupt` 歇下，`SessionEnd` 下线。
///   托管的会话另有自己进程的 `turn/started`、`turn/completed` 通知管忙闲（钩子没装好时也对）。
/// - 子代理只认 app-server 的子线程推送（托管的是自己的进程，终端的是常驻服务：子线程没有订阅者，它的推送广播给所有连接，实测、文档没写）。
///   钩子不行：`SubagentStop` 只在正常做完时发，出错、被停没有；v2 `followup_task` 再跑不发 `SubagentStart`。
///   子线程按 `thread/read` 的 `parentThreadId` 一路找到会话（`threads`）；它的一轮开始是在跑，结束按状态落定（做完、出错、被停），
///   卸载或出错也算落定，每条推送是一次进展。启动时从常驻服务已载入的线程补回名册。
///   在飞（`SessionFacts.inFlight`）是在跑的，加上父线程歇着时落定、结果还没交给一轮的；父线程这一轮在跑时落定的，结果并进这一轮。
///   父线程歇着时子代理做完，Codex 不自己接着跑（结果在它的历史或邮箱里等下一轮）：最后一个落定时 CuePad 补一轮空输入（`wake`）。
///   会话 id 是 `<线程 id>.<承载进程>`：终端会话的承载进程是钩子的父进程（常驻服务）；托管的是 CuePad 起的进程，它的钩子按环境里的
///   `HostMark` 认回（`codex` 可能是外壳，钩子的父进程是外壳起的子进程，不按进程号认）。
///   承载进程退出时它上面的会话都下线。常驻服务里的线程在终端退出后还会挂着（没有订阅者、闲置约 30 分钟后才卸载并报 `SessionEnd`，
///   实测、文档没写），这段时间它仍在线、能收话。
/// - 正在说的话（`PiDraft`）与上下文余量只有托管的会话有：增量与用量只发给订阅了线程的连接（自己起的进程），`CodexRPC` 累积好
///   （回答项说完换成全文）交给桥；终端里的会话不订阅，也就没有。
/// - 控制只经 app-server 的接口，不为观察而订阅（`thread/resume` 会把终端的事件与审批抢走）：说话是 `turn/start`，在跑就先
///   `turn/interrupt`（`turn/steer` 要等在跑的工具做完才读到，不是打断），停止是 `turn/interrupt`，换模型与强度是
///   `thread/settings/update`，改名是 `thread/name/set`，斜杠命令只有映射得上的几个。常驻服务把 `thread/status/changed`、
///   `thread/name/updated`、`thread/closed` 广播给所有连接：钩子漏掉的歇下（出错时没有 `Stop`）与改名靠它们补上。
///   常驻服务的控制 socket 在哪由 `codex app-server daemon version` 告诉（服务在跑时才有），不自己拼路径。
/// - 权限确认经 `PermissionRequest` 钩子：Codex 先问钩子、钩子没给决定才在终端里弹框。终端会话按人在不在分（`PresenceGate`）；
///   托管的会话没有终端，总是挂住。在终端里按 Esc 停下这一轮会收回挂住的调用。
/// - Plan 模式：托管会话用 `/plan [话]` 进、`/default` 回默认模式（`thread/settings/update` 的 `collaborationMode`，同终端界面的 /plan），
///   终端会话在终端里切。Plan 模式提问有两种：
///   - 不挡着这一轮的（`request_user_input_async`，0.162 起 Plan 模式的默认）：Codex 登记了问题就接着做事、睡着等或歇下，你的下一句话就是答案。
///     终端与托管的会话都经 `PostToolUse` 钩子（工具被接受了才有）显示成等你回答，从 CuePad 作答就是对它说这句话（`deliver`），
///     你说了下一句（`UserPromptSubmit`）就收起。
///   - 挡着这一轮的（`request_user_input`）只发给开出线程的连接：终端会话的只能在终端里答（CuePad 只显示）；
///     托管会话的经 `item/tool/requestUserInput` 发给 CuePad，只有一个问题时能从 CuePad 答。
@MainActor
public final class CodexRuntime: AgentRuntime, SessionLink {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "codex")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    /// 这家的可执行文件（检测时挑中的那个，`AgentStatus.executable`）；没有为 nil
    private let codex: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let gate: PresenceGate
    private var tracked: [PiSession.ID: Tracked] = [:]
    /// CuePad 托管的进程（进程号 → 进程）
    private var hosted: [Int32: CodexRPC] = [:]
    /// 托管进程环境里的标记（`HostMark`）→ 进程号
    private var marks: [String: Int32] = [:]
    private var daemon: CodexRPC?
    private var connecting: Task<CodexRPC, any Error>?
    /// 常驻服务的控制 socket（服务在跑时问到的）
    private var controlSocket: String?
    private var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    /// 收到过推送的线程（`<线程 id>.<承载进程>`）属于谁：会话的子代理（名字、角色）、不是子代理（Codex 自己起的临时线程等），
    /// 或还在问 Codex（先攒着它的推送）
    private var threads: [String: Owner] = [:]
    private enum Owner {
        case asking([(method: String, params: JSONValue)])
        case session(PiSession.ID, name: String, role: String)
        case foreign
    }
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    private var models: [CodexModel]?
    private var stopped = true
    /// 终端会话哪些接上桥（`follow`）；给之前一个都不接
    private var scope = PiHistoryScope.sessions([])

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, codex: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, presence: any UserPresence = SystemPresence()
    ) {
        self.codex = codex
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locate = locate
        gate = PresenceGate(presence: presence)
    }

    /// 一个在线会话在这里的状态（快照在桥上，由 `facts` 推出）。
    /// 以一句话开新一轮的进展：正在停下这一轮，或这一轮已经结束（被停下或恰好自己做完）、等这句开出新的一轮。
    private enum Restart { case stopping, stopped }

    private final class Tracked {
        let id: PiSession.ID
        let threadID: String
        let pid: Int32
        var facts = SessionFacts()
        /// 要你回答的那一个怎么回给 Codex（与 `facts.questions` 一一对应，只有一个）
        var reply: Reply?
        /// 父线程歇着时落定、结果还没交给一轮的子代理（线程 id）：有没有交回结果（做完、出错交回；被停下的不交）
        var unread: [String: Bool] = [:]
        /// 子代理最后说的一段话：落定时作那句说明
        var lastWords: [String: String] = [:]
        /// 这一轮报过的错误原文（`error` 通知），出错歇下时用
        var lastError: String?
        /// CuePad 正以一句话开新一轮（`deliver`）：期间一轮结束不算歇下，接着就是这句开的那一轮
        var restarting: Restart?
        var skills: [(name: String, path: String)] = []

        init(id: PiSession.ID, threadID: String, pid: Int32) {
            self.id = id
            self.threadID = threadID
            self.pid = pid
        }

        enum Reply {
            /// 阻塞着的 `PermissionRequest` 钩子（人不在而挂住的带着凭据）
            case hook(AgentHookCall, hold: UUID?)
            /// 托管线程的 `item/tool/requestUserInput`：服务端请求的 id、问题的 id
            case request(CodexRPC, id: JSONValue, question: String)
        }
    }

    // MARK: AgentRuntime

    public func start() throws {
        guard stopped else { return }
        stopped = false
        hooks.handle(.codex) { [weak self] call in
            guard let self, !self.stopped else { return call.finish() }
            self.hook(call)
        }
    }

    public func follow(_ scope: PiHistoryScope) {
        self.scope = scope
        for session in tracked.values where hosted[session.pid] == nil && !scope.covers(sessionID: session.threadID) { detach(session.id) }
        if scope != .sessions([]) { Task { await discover() } }
    }

    public func stop() -> @concurrent @Sendable () async -> Void {
        stopped = true
        for session in tracked.values { release(session) }
        for watcher in exitWatchers.values { watcher.cancel() }
        exitWatchers = [:]
        daemon?.close()
        daemon = nil
        let waits = hosted.values.map { rpc in Task { await rpc.shutdown() } }
        return { for wait in waits { await wait.value } }
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let id = try await launch { rpc in
            let started = try await rpc.call("thread/start", ["cwd": .string(directory.path)])
            return self.attachHosted(started, rpc: rpc, launchToken: launchToken)
        }
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 接着一个已结束的会话：还在常驻服务里（终端开着它，或终端退出后它还挂着）就经控制 socket 接上，不另开一份；
    /// 否则在后台起进程恢复它。恢复时它被别处拿着写（终端里刚开）也改走控制 socket；常驻服务里也没有它才报错。
    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: session.id) { return live.id }
        if let id = try await adoptFromDaemon(session.id) { return id }
        do {
            return try await launch { rpc in
                let resumed = try await rpc.call(
                    "thread/resume", ["threadId": .string(session.id), "path": .string(session.path), "excludeTurns": true])
                return self.attachHosted(resumed, rpc: rpc, launchToken: nil)
            }
        } catch CodexRPCError.server(_, let message) where message.contains("active writer") {
            if let id = try await adoptFromDaemon(session.id) { return id }
            throw AgentRuntimeError.openElsewhere
        }
    }

    // MARK: 托管进程

    /// `codex` 与给它的环境：配置目录与钩子 socket 目录照 `AgentPaths` 定（隔离测试里指到临时目录）。
    private func executable() async throws -> (url: URL, environment: [String: String]) {
        guard let codex = await codex() else { throw AgentRuntimeError.notInstalled(.codex) }
        let locator = await locate()
        return (codex, locator.environment(launching: codex, overrides: paths.environment.merging([
            "CODEX_HOME": paths.home(of: .codex).path, "CUEPAD_PI_SOCKET_DIR": paths.pi.socketDirectory.path,
        ]) { $1 }))
    }

    /// 起一个托管进程交给 `body`；连同握手至多 `AgentTimeouts.launch`，超时或出错时停掉进程。
    private func launch(_ body: @escaping @MainActor (CodexRPC) async throws -> PiSession.ID) async throws -> PiSession.ID {
        let codex = try await executable()
        let mark = UUID().uuidString
        let rpc = try await CodexRPC.launch(codex.url, environment: codex.environment.merging([HostMark.variable: mark]) { $1 })
        host(rpc, mark: mark)
        do {
            return try await withDeadline(AgentTimeouts.launch, orThrow: AgentRuntimeError.launchTimedOut(.codex)) { try await body(rpc) }
        } catch {
            await rpc.shutdown()
            throw error as? CodexRPCError == .timedOut ? AgentRuntimeError.launchTimedOut(.codex) : error
        }
    }

    private func host(_ rpc: CodexRPC, mark: String) {
        let pid = rpc.pid
        hosted[pid] = rpc
        marks[mark] = pid
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        rpc.onRequest = { [weak self, weak rpc] method, id, params in
            guard let self, let rpc, method == "item/tool/requestUserInput" else { return false }
            return self.userInput(params, id: id, on: rpc)
        }
        rpc.onDraft = { [weak self] thread, draft in self?.bridge.setDraft("\(thread).\(pid)", draft) }
        rpc.onClose = { [weak self] in self?.processGone(pid) }
    }

    private func attachHosted(_ result: JSONValue, rpc: CodexRPC, launchToken: String?) -> PiSession.ID {
        var session = makeSession(result["thread"] ?? .object([:]), pid: rpc.pid)
        session.hosted = true
        session.launchToken = launchToken
        attach(session)
        return session.id
    }

    // MARK: 常驻服务

    /// 常驻服务的控制 socket：`codex app-server daemon version` 在服务跑着时给出它；没跑为 nil（之后再问）。
    private func daemonSocket() async -> String? {
        if let controlSocket { return controlSocket }
        guard let codex = try? await executable(),
              let result = await ChildProcess.run(codex.url, ["app-server", "daemon", "version"], environment: codex.environment, timeout: .seconds(10)),
              let info = JSONValue.parse(Data(result.output.utf8)), info["status"]?.string == "running", let path = info["socketPath"]?.string
        else { return nil }
        controlSocket = path
        return path
    }

    /// 连上常驻服务（已连着就用那条）；服务没跑为 nil。
    private func daemonConnection() async throws -> CodexRPC? {
        if let daemon, !daemon.isClosed { return daemon }
        if let connecting { return try await connecting.value }
        guard let path = await daemonSocket() else { return nil }
        let task = Task { try await CodexRPC.connect(socket: path) }
        connecting = task
        defer { connecting = nil }
        let rpc = try await task.value
        let pid = rpc.pid
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        rpc.onClose = { [weak self, weak rpc] in
            if let self, self.daemon === rpc { self.daemon = nil }
        }
        daemon = rpc
        watchExit(pid)
        return rpc
    }

    /// 启动时把常驻服务里已经载入的线程接上（CuePad 晚于终端里的会话启动）：会话先接上，子代理的线程再补进它们的名册。
    private func discover() async {
        do {
            guard let rpc = try await daemonConnection() else { return }
            let loaded = try await rpc.call("thread/loaded/list", [:])
            var children: [JSONValue] = []
            for threadID in loaded["data"]?.array?.compactMap(\.string) ?? [] where tracked["\(threadID).\(rpc.pid)"] == nil {
                // Codex 自己起的临时线程（起标题等）不是会话
                guard let thread = try await rpc.call("thread/read", ["threadId": .string(threadID)])["thread"],
                      thread["ephemeral"]?.bool != true else { continue }
                if thread["parentThreadId"]?.string != nil {
                    children.append(thread)
                } else if scope.covers(sessionID: threadID) {
                    try await adopt(thread, on: rpc)
                }
            }
            for child in children {
                guard let id = child["id"]?.string, threads["\(id).\(rpc.pid)"] == nil else { continue }
                threads["\(id).\(rpc.pid)"] = .asking([])
                await register(child, on: rpc)
            }
        } catch {
            Self.log.notice("没能读出常驻服务里的会话：\(String(describing: error))")
        }
    }

    private func adoptFromDaemon(_ threadID: String) async throws -> PiSession.ID? {
        guard let rpc = try? await daemonConnection() else { return nil }
        let loaded = try await rpc.call("thread/loaded/list", [:])
        guard loaded["data"]?.array?.contains(.string(threadID)) == true,
              let thread = try await rpc.call("thread/read", ["threadId": .string(threadID)])["thread"],
              thread["parentThreadId"]?.string == nil, thread["ephemeral"]?.bool != true else { return nil }
        return try await adopt(thread, on: rpc)
    }

    /// 接上一个线程（`thread/read` 读到的，不是子代理）。
    @discardableResult
    private func adopt(_ thread: JSONValue, on rpc: CodexRPC) async throws -> PiSession.ID {
        let threadID = thread["id"]?.string ?? ""
        let id = "\(threadID).\(rpc.pid)"
        if tracked[id] != nil { return id }
        // 正在跑一轮：接上时就是工作中（钩子要等下一个事件才来），从这一轮的开始算
        let last = try await Self.lastTurn(threadID, on: rpc)
        let running = last?["status"]?.string == "inProgress"
        if tracked[id] != nil { return id }
        attach(makeSession(thread, pid: rpc.pid)) { session in
            if running { self.startTurn(session, at: Self.startedAt(last)) }
        }
        return id
    }

    // MARK: 会话

    private func makeSession(_ thread: JSONValue, pid: Int32) -> PiSession {
        let threadID = thread["id"]?.string ?? ""
        var session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: thread["path"]?.string.map { URL(filePath: $0) },
            pid: pid, cwd: URL(filePath: thread["cwd"]?.string ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            extensionVersion: 0, state: .settled, stateSince: .now)
        apply(thread, to: &session)
        return session
    }

    /// 线程的名字、首条消息、模型与强度写进快照（`thread/read`、`thread/start`、`thread/resume` 给的都是这个形状）。
    private func apply(_ thread: JSONValue, to session: inout PiSession) {
        session.name = thread["name"]?.string
        if let preview = thread["preview"]?.string, !preview.isEmpty { session.firstMessage = String(preview.prefix(PiSessionName.firstMessageLimit)) }
        if let model = thread["model"]?.string {
            session.model = models?.first { $0.id == model }?.option
                ?? PiModelOption(key: PiModelKey(provider: CodexModel.provider, id: model), name: model, thinkingLevels: [])
            session.availableModels = (models ?? []).map(\.option)
        }
        session.thinking = thread["reasoningEffort"]?.string.map(CodexModel.thinking)
    }

    private func attach(_ session: PiSession, prepare: (Tracked) -> Void = { _ in }) {
        let entry = Tracked(id: session.id, threadID: session.sessionID, pid: session.pid)
        prepare(entry)
        tracked[session.id] = entry
        var session = session
        entry.facts.publish(to: &session)
        bridge.attach(session, via: self)
        watchExit(session.pid)
        refresh(session.id, skills: true)
    }

    private func watchExit(_ pid: Int32) {
        guard exitWatchers[pid] == nil else { return }
        exitWatchers[pid] = ProcessExitWatcher(pid: pid) { [weak self] in self?.processGone(pid) }
    }

    /// 承载进程退出了：它上面的会话都下线。
    private func processGone(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        hosted[pid] = nil
        marks = marks.filter { $0.value != pid }
        threads = threads.filter { !$0.key.hasSuffix(".\(pid)") }
        for session in tracked.values where session.pid == pid { detach(session.id) }
    }

    private func detach(_ id: PiSession.ID) {
        guard let session = tracked.removeValue(forKey: id) else { return }
        threads = threads.filter { if case .session(id, _, _) = $0.value { false } else { true } }
        release(session)
        bridge.detach(id, reason: .closed(reason: "quit"))
    }

    /// 从 Codex 重新读名字、模型与强度（`thread/read`），可换的模型（`model/list`）与 skill（`skills/list`，斜杠命令）。
    private func refresh(_ id: PiSession.ID, skills: Bool = false) {
        Task {
            do {
                guard let session = tracked[id] else { return }
                let rpc = try await control(session)
                if models == nil { models = try await CodexModel.list(rpc) }
                if skills, let cwd = bridge.session(id: id)?.cwd {
                    let listed = try await rpc.call("skills/list", ["cwds": [.string(cwd.path)]])
                    let entries = (listed["data"]?.array?.first?["skills"]?.array ?? []).filter { $0["enabled"]?.bool != false }
                    session.skills = entries.compactMap { entry in entry["name"]?.string.flatMap { name in entry["path"]?.string.map { (name, $0) } } }
                    let modes = hosted[session.pid] == nil ? [] : Self.modeCommands
                    let commands = Self.builtinCommands + modes + entries.compactMap { entry -> PiSlashCommand? in
                        guard let name = entry["name"]?.string else { return nil }
                        return PiSlashCommand(name: "skill:\(name)", summary: entry["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.skill))
                    }
                    bridge.update(id) { $0.commands = commands }
                }
                let read = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])
                guard let thread = read["thread"] else { return }
                bridge.update(id) { self.apply(thread, to: &$0) }
            } catch {
                Self.log.notice("没能读出 Codex 会话的设置：\(String(describing: error))")
            }
        }
    }

    /// 能从 CuePad 执行的内置命令：Codex 的斜杠命令是终端界面自己实现的，只有这几个有对应的接口。
    private static let builtinCommands = [
        PiSlashCommand(name: "compact", summary: "压缩上下文", source: .known(.builtin)),
        PiSlashCommand(name: "name", summary: "给会话改名", source: .known(.builtin), hint: "<名字>"),
        PiSlashCommand(name: "model", summary: "换模型", source: .known(.builtin), hint: "<模型>"),
    ]

    /// 托管会话切协作模式（终端会话的模式归终端界面管）
    private static let modeCommands = [
        PiSlashCommand(name: "plan", summary: "进 Plan 模式：先问清楚、出计划，不动手", source: .known(.builtin), hint: "[话]"),
        PiSlashCommand(name: "default", summary: "回默认模式", source: .known(.builtin)),
    ]

    /// 会话的控制通道：托管的是它的进程，终端里的是常驻服务（钩子的父进程就是它才算；`codex exec` 之类没有控制接口）。
    private func control(_ session: Tracked) async throws -> CodexRPC {
        if let rpc = hosted[session.pid] { return rpc }
        guard let rpc = try await daemonConnection(), rpc.pid == session.pid else { throw PiBridgeError.unsupported }
        return rpc
    }

    private func publish(_ session: Tracked) {
        bridge.update(session.id) { session.facts.publish(to: &$0) }
    }

    // MARK: 钩子

    private func hook(_ call: AgentHookCall) {
        guard let input = JSONValue.parse(call.envelope.input), let event = input["hook_event_name"]?.string,
              let threadID = input["session_id"]?.string else { return call.finish() }
        let pid = hostedPID(of: call.envelope, thread: threadID) ?? call.envelope.pid
        let id = "\(threadID).\(pid)"
        if event == "SessionEnd" {
            call.finish()
            return detach(id)
        }
        let agent = input["agent_id"]?.string
        guard tracked[id] != nil || scope.covers(sessionID: threadID) else { return call.finish() }
        let session = tracked[id] ?? adoptFromHook(threadID, pid: pid, input, transcript: agent == nil)
        let tool = input["tool_name"]?.string ?? ""
        let now = Date.now
        switch event {
        case "PermissionRequest":
            // 子代理要的确认也挂在这个会话上问
            return ask(session, call: call, input)
        case _ where agent != nil:
            // 子代理自己线程里的事件（session_id 是同一棵树的根，agent_id 是它自己）：只更新它在做什么
            if event == "PreToolUse", let agent { session.facts.updateSubagent(agent, at: now) { $0.action = ToolDetail.line(tool, input["tool_input"]) } }
        case "UserPromptSubmit":
            session.facts.standingQuestion = nil
            // 钩子里没有时刻：用收到它的时刻
            startTurn(session, at: now)
            bridge.update(id) { s in
                if s.firstMessage == nil, let prompt = input["prompt"]?.string, !prompt.isEmpty {
                    s.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
                }
            }
            refresh(id)
        case "PreToolUse":
            if tool == "request_user_input", session.reply == nil {
                // 终端会话的 Plan 模式提问只发给终端界面：CuePad 只显示（托管的经 `item/tool/requestUserInput` 来）
                session.facts.questions = [Self.userInput(input["tool_input"] ?? .object([:]), promptID: nil)]
            } else {
                session.facts.work(.tool, detail: ToolDetail.line(tool, input["tool_input"]))
            }
        case "PostToolUse" where tool == Self.asyncQuestionTool:
            session.facts.standingQuestion = Self.asyncQuestion(input["tool_input"])
            session.facts.work(.thinking)
        case "PostToolUse":
            if session.reply == nil { session.facts.questions = [] }
            session.facts.work(.thinking)
        case "PreCompact":
            session.facts.compacting = true
        case "PostCompact":
            session.facts.compacting = false
        case "Stop", "Interrupt":
            endTurn(session)
            refresh(id)
        default:
            break
        }
        call.finish()
        publish(session)
    }

    /// 钩子来自哪个托管进程：环境里带着它的标记，且线程是它承载的（或它还没有上桥的线程：刚开、刚接着）。
    /// Agent 在托管会话里再起的 codex 也继承标记，但线程不同，算终端会话。
    private func hostedPID(of envelope: AgentHookEnvelope, thread: String) -> Int32? {
        guard let mark = envelope.environment[HostMark.variable], let pid = marks[mark] else { return nil }
        return tracked["\(thread).\(pid)"] != nil || !tracked.values.contains(where: { $0.pid == pid }) ? pid : nil
    }

    /// 钩子先于其他途径报出的会话（终端里刚开、或 CuePad 晚启动）：接上桥，名字与模型随后从 Codex 读。
    /// 子代理的钩子（`transcript` 为 false）带的会话文件是子代理自己的，不用。
    private func adoptFromHook(_ threadID: String, pid: Int32, _ input: JSONValue, transcript: Bool) -> Tracked {
        let session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex,
            sessionFile: transcript ? input["transcript_path"]?.string.map { URL(filePath: $0) } : nil,
            pid: pid, cwd: URL(filePath: input["cwd"]?.string ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            extensionVersion: 0, state: .settled, stateSince: .now)
        attach(session)
        return tracked[session.id]!
    }

    // MARK: 等你回答

    /// 权限确认：托管的会话总是挂住等 CuePad 作答；终端会话按人在不在（`PresenceGate`）：人在就放行、终端弹框，CuePad 只显示。
    /// 钩子先走了（终端里停下了这一轮）就收起问题。
    private func ask(_ session: Tracked, call: AgentHookCall, _ input: JSONValue) {
        let arguments = input["tool_input"] ?? .object([:])
        let command = arguments["command"]?.string
        let text = PermissionWording.question(
            .codex, command == nil ? "使用 \(input["tool_name"]?.string.map(ToolDetail.name) ?? "工具")" : "运行命令", [command, arguments["description"]?.string])
        release(session)
        let promptID = UUID().uuidString
        var hold: UUID?
        if hosted[session.pid] == nil {
            hold = gate.hold { [weak self, weak session] in
                guard let self, let session, case .hook(let held, _) = session.reply, held === call else { return }
                self.handBack(session)
            }
            guard hold != nil else {
                call.finish()
                session.facts.questions = [PiQuestion(promptID: nil, kind: .confirm, text: text)]
                return publish(session)
            }
        }
        session.reply = .hook(call, hold: hold)
        session.facts.questions = [PiQuestion(promptID: promptID, kind: .confirm, text: text)]
        call.onClose = { [weak self, weak session] in
            guard let self, let session, case .hook(let held, _) = session.reply, held === call else { return }
            self.release(session)
            session.facts.questions = []
            self.publish(session)
        }
        publish(session)
    }

    /// 人回来了：挂住的放行，终端补弹；CuePad 里还显示，只能在终端里答。
    private func handBack(_ session: Tracked) {
        guard case .hook(let call, _) = session.reply else { return }
        session.reply = nil
        call.finish()
        session.facts.questions = session.facts.questions.map { PiQuestion(promptID: nil, kind: $0.kind, text: $0.text, options: $0.options) }
        publish(session)
    }

    /// 放掉在等的（挂住的钩子放行；托管线程的提问不再等），问题由调用方收起。
    private func release(_ session: Tracked) {
        if case .hook(let call, let hold) = session.reply {
            call.finish()
            gate.drop(hold)
        }
        session.reply = nil
    }

    /// 托管线程的 Plan 模式提问（`item/tool/requestUserInput`）：只有一个问题时能从 CuePad 答（有选项是单选，否则填文字；保密的不答）。
    private func userInput(_ params: JSONValue, id: JSONValue, on rpc: CodexRPC) -> Bool {
        guard let threadID = params["threadId"]?.string, let session = tracked["\(threadID).\(rpc.pid)"] else { return false }
        let questions = params["questions"]?.array ?? []
        let answerable = questions.count == 1 && questions.first?["isSecret"]?.bool != true
        let question = Self.userInput(params, promptID: answerable ? UUID().uuidString : nil)
        release(session)
        if answerable, let first = questions.first?["id"]?.string { session.reply = .request(rpc, id: id, question: first) }
        session.facts.questions = [question]
        publish(session)
        return answerable
    }

    /// Plan 模式的提问（`request_user_input` 的参数，一次可能几个，显示第一个）：有选项是单选（`isOther` 的还能自己填），否则填文字；
    /// 标题与问题换行连接。
    private static func userInput(_ arguments: JSONValue, promptID: String?) -> PiQuestion {
        let first = arguments["questions"]?.array?.first ?? .object([:])
        let text = [first["header"]?.string, first["question"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let options = (first["options"]?.array ?? []).compactMap { $0["label"]?.string }
        return PiQuestion(
            promptID: promptID, kind: options.isEmpty ? .text : .select, text: String(text.prefix(500)), options: options,
            allowsOther: first["isOther"]?.bool == true)
    }

    static let asyncQuestionTool = "request_user_input_async"

    /// 不挡着这一轮的提问（`request_user_input_async` 的参数，一次可以几个，标题就是完整的问题）：只有一个时照它的选项单选，
    /// 也能自己填（Codex 的界面总给自由作答）；几个时合成一道文字题，一行一问、选项写在后面。
    static func asyncQuestion(_ arguments: JSONValue?) -> PiQuestion? {
        let questions = (arguments?["questions"]?.array ?? []).compactMap { question -> (title: String, options: [String])? in
            guard let title = question["title"]?.string, !title.isEmpty else { return nil }
            return (title, (question["options"]?.array ?? []).compactMap(\.string))
        }
        guard let first = questions.first else { return nil }
        guard questions.count > 1 else {
            return PiQuestion(
                promptID: UUID().uuidString, kind: first.options.isEmpty ? .text : .select, text: String(first.title.prefix(500)),
                options: first.options, allowsOther: !first.options.isEmpty)
        }
        let text = questions.map { $0.options.isEmpty ? $0.title : "\($0.title)（\($0.options.joined(separator: " / "))）" }.joined(separator: "\n")
        return PiQuestion(promptID: UUID().uuidString, kind: .text, text: String(text.prefix(500)))
    }

    /// 作答：权限确认写回钩子（允许或拒绝，附一句给模型看的原因），托管线程挡着这一轮的提问回给服务端请求，
    /// 不挡着的提问把答案当你的下一句话说给它（与发话同一规则）。
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        guard let session = tracked[id], let question = session.facts.question else { throw PiBridgeError.rejected("no_prompt") }
        guard question.promptID == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        guard let reply = session.reply else {
            let text: String
            switch answer {
            case .option(let option) where question.options.contains(option): text = option
            case .text(let written) where question.acceptsText: text = written
            default: throw PiBridgeError.rejected("bad_answer")
            }
            try await deliver(CodexRPC.input(text: text, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            session.facts.standingQuestion = nil
            return publish(session)
        }
        switch (reply, answer) {
        case (.hook(let call, let hold), .confirmed(let allowed)):
            let decision: JSONValue = ["behavior": allowed ? "allow" : "deny", "message": .string(allowed ? PermissionWording.allowed : PermissionWording.denied)]
            call.reply(JSONValue.object(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]).data)
            gate.drop(hold)
        case (.request(let rpc, let requestID, let questionID), .option(let text)) where question.options.contains(text),
             (.request(let rpc, let requestID, let questionID), .text(let text)) where question.acceptsText:
            rpc.respond(to: requestID, result: ["answers": [questionID: ["answers": [.string(text)]]]])
        default:
            throw PiBridgeError.rejected("bad_answer")
        }
        session.reply = nil
        session.facts.questions = []
        publish(session)
    }

    // MARK: 通知

    private func notification(_ method: String, _ params: JSONValue, from pid: Int32) {
        // 子代理的线程没有 `thread/started`：报出来的顶层线程不是子代理（Codex 起的临时线程等），之后它的推送不必去问
        if method == "thread/started", let thread = params["thread"], let id = thread["id"]?.string, thread["parentThreadId"]?.string == nil {
            threads["\(id).\(pid)"] = threads["\(id).\(pid)"] ?? .foreign
        }
        guard let threadID = params["threadId"]?.string else { return }
        guard let session = tracked["\(threadID).\(pid)"] else { return child(method, params, thread: threadID, pid: pid) }
        switch method {
        case "thread/name/updated":
            bridge.update(session.id) { $0.name = params["threadName"]?.string }
            return
        case "thread/status/changed":
            switch params["status"]?["type"]?.string {
            // 钩子漏报的歇下（出错的一轮没有 Stop）；钩子的 Stop 晚到也只是再歇一次。睡着等（`clock.sleep`）时不报 idle（托管与终端实测）
            case "idle" where session.facts.running:
                endTurn(session)
            case "systemError":
                endTurn(session, failure: session.lastError ?? "Codex 出错了")
                if session.lastError == nil { readFailure(session) }
            default: return
            }
        case "error" where params["willRetry"]?.bool != true:
            // 出错的原文（常驻服务也广播）；随后的 systemError 或失败的 turn/completed 用它
            session.lastError = CodexModel.failure(of: params)
            return
        // 以下只有开出这个线程的连接（托管的进程）收得到
        case "turn/started":
            session.lastError = nil
            guard !session.facts.running else { return }
            startTurn(session, at: Self.startedAt(params["turn"]))
        case "turn/completed" where params["turn"]?["status"]?.string == "failed":
            // 失败的一轮没有 Stop 钩子，状态停在这里
            endTurn(session, failure: session.lastError ?? CodexModel.failure(of: params["turn"]))
        case "turn/completed":
            guard session.facts.running else { return }
            endTurn(session)
        case "serverRequest/resolved":
            // 服务端请求被别处答了或收回了
            guard case .request = session.reply else { return }
            session.reply = nil
            session.facts.questions = []
        case "thread/closed":
            return detach(session.id)
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], let window = usage["modelContextWindow"]?.int else { return }
            let used = usage["last"]?["totalTokens"]?.int
            bridge.update(session.id) { $0.context = PiContextUsage(tokens: used, window: window) }
            return
        default:
            return
        }
        publish(session)
    }

    /// 出错的原文只在开出线程的连接上（`error` 通知），常驻服务只广播 `systemError`：从最近一轮读出它的错误。
    private func readFailure(_ session: Tracked) {
        Task {
            guard let rpc = try? await control(session),
                  let turn = try? await Self.lastTurn(session.threadID, on: rpc), turn["status"]?.string == "failed", tracked[session.id] === session,
                  !session.facts.running else { return }
            session.facts.failure = CodexModel.failure(of: turn)
            publish(session)
        }
    }

    /// 这一轮结束：挂着的钩子收回；CuePad 正以一句话开新一轮时只记下（见 `deliver`），不歇下。
    private func endTurn(_ session: Tracked, failure: String? = nil) {
        release(session)
        guard session.restarting == nil else { session.restarting = .stopped; return }
        session.facts.endTurn(failure: failure)
    }

    // MARK: 子代理

    /// 开始新的一轮（`start` 是这一轮开始的时刻，早于它可能的结束：Codex 给的 `Turn.startedAt`，CuePad 补开的是发出的时刻，
    /// 钩子没有时刻用收到的时刻）：歇着时落定的子代理的结果随这一轮交给模型，不再在飞。开始一轮只经这里。
    private func startTurn(_ session: Tracked, at start: Date) {
        session.facts.startTurn(at: start)
        session.facts.inFlight.subtract(session.unread.keys)
        session.unread = [:]
    }

    /// 子线程的推送里管生命周期与进展的
    private static let childMethods: Set = ["turn/started", "turn/completed", "thread/status/changed", "item/started", "item/completed"]

    /// 不是会话的线程的推送：子代理的交给它的会话；第一次见的先问 Codex 它是谁的（`register`），问的时候攒着之后的推送。
    private func child(_ method: String, _ params: JSONValue, thread: String, pid: Int32) {
        guard Self.childMethods.contains(method) else { return }
        let key = "\(thread).\(pid)"
        switch threads[key] {
        case .session(let id, let name, let role):
            guard let session = tracked[id] else { return }
            childEvent(method, params, child: thread, name: name, role: role, in: session)
        case .foreign:
            return
        case .asking(let queued):
            threads[key] = .asking(queued + [(method, params)])
        case nil:
            threads[key] = .asking([(method, params)])
            Task { await resolve(thread, pid: pid) }
        }
    }

    private func resolve(_ thread: String, pid: Int32) async {
        guard let rpc = hosted[pid] ?? daemon.flatMap({ $0.pid == pid ? $0 : nil }),
              let info = try? await rpc.call("thread/read", ["threadId": .string(thread)])["thread"] else {
            threads["\(thread).\(pid)"] = .foreign
            return
        }
        await register(info, on: rpc)
    }

    /// 认下一个线程（`thread/read` 读到的，推送先攒着）：是子代理就补进会话的名册——最近一轮还在跑的算在飞（没赶上它这一轮开始：CuePad 晚启动），
    /// 歇着的按它最近一轮的结果落定（还没跑过的等它开始）；再按先后补上攒着的推送。
    private func register(_ thread: JSONValue, on rpc: CodexRPC) async {
        guard let child = thread["id"]?.string else { return }
        let key = "\(child).\(rpc.pid)"
        let owner = await owner(of: thread, on: rpc)
        var last: JSONValue?
        if case .session = owner { last = try? await Self.lastTurn(child, on: rpc) }
        let running = last?["status"]?.string == "inProgress"
        guard case .asking(let queued) = threads[key] else { return }
        threads[key] = owner
        if case .session(let id, let name, let role) = owner, let session = tracked[id],
           !session.facts.subagents.contains(where: { $0.id == child }), running || last != nil {
            let date = { (field: String) in thread[field]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now }
            session.facts.startSubagent(child, name: name, role: role, at: date("createdAt"))
            if running {
                session.facts.updateSubagent(child, at: date("updatedAt")) { $0.progressAt = date("updatedAt") }
                session.facts.inFlight.insert(child)
            } else {
                session.facts.settleSubagent(child, Self.phase(of: last), summary: nil, at: date("updatedAt"))
            }
            publish(session)
        }
        for (method, params) in queued { self.child(method, params, thread: child, pid: rpc.pid) }
    }

    /// 线程（`thread/read` 读到的）属于哪个会话：顺着 `parentThreadId` 往上找到接着的会话或已认得的子代理（孙代理算进同一个会话）。
    /// 名字是派它时给的任务名（v2 的 `agent_path` 末段），没有就用 Codex 起的昵称。
    private func owner(of thread: JSONValue, on rpc: CodexRPC) async -> Owner {
        let spawn = thread["source"]?["subAgent"]?["thread_spawn"]
        let role = thread["agentRole"]?.string ?? spawn?["agent_role"]?.string ?? "default"
        let path = spawn?["agent_path"]?.string.flatMap { $0.split(separator: "/").last.map(String.init) }
        let name = path ?? thread["agentNickname"]?.string ?? role
        var current = thread
        while let parent = current["parentThreadId"]?.string {
            let key = "\(parent).\(rpc.pid)"
            if let session = tracked[key] { return .session(session.id, name: name, role: role) }
            if case .session(let id, _, _) = threads[key] { return .session(id, name: name, role: role) }
            guard let up = try? await rpc.call("thread/read", ["threadId": .string(parent)])["thread"] else { break }
            current = up
        }
        return .foreign
    }

    private func childEvent(_ method: String, _ params: JSONValue, child: String, name: String, role: String, in session: Tracked) {
        let now = Date.now
        switch method {
        case "turn/started":
            // 再跑一轮（v2 的 followup_task、v1 的 send_input）也是在跑
            session.facts.runSubagent(child, name: name, role: role, at: now)
            session.unread[child] = nil
            session.facts.inFlight.insert(child)
        case "turn/completed":
            let turn = params["turn"]
            let phase = Self.phase(of: turn)
            settle(child, phase, summary: phase == .failed ? CodexModel.failure(of: turn) : session.lastWords[child], in: session)
        case "thread/status/changed":
            switch params["status"]?["type"]?.string {
            case "systemError": settle(child, .failed, summary: session.lastWords[child], in: session)
            case "notLoaded": settle(child, .interrupted, summary: nil, in: session)
            default: return
            }
        default:
            if method == "item/completed", let item = params["item"], item["type"]?.string == "agentMessage", let text = item["text"]?.string {
                session.lastWords[child] = text
            }
            session.facts.updateSubagent(child, at: now) { $0.progressAt = now }
        }
        publish(session)
    }

    /// 一轮的开始时刻（`Turn.startedAt`，Unix 秒）；没给的（`turn/start` 的回应里是 null）为此刻。
    private static func startedAt(_ turn: JSONValue?) -> Date {
        turn?["startedAt"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    /// 线程最近的一轮。接上时在不在跑看它（`inProgress`），不看 `thread/read` 给的线程状态：子代理睡着等（`clock.sleep`）时
    /// 读到的是 idle，它这一轮还没结束（实测）。推送里的 idle 不同，睡着等时不报（见 `notification`）。
    private static func lastTurn(_ thread: String, on rpc: CodexRPC) async throws -> JSONValue? {
        try await rpc.call("thread/turns/list", ["threadId": .string(thread), "limit": 1])["data"]?.array?.first
    }

    /// 一轮的结束状态（`Turn.status`）→ 子代理落定的样子
    private static func phase(of turn: JSONValue?) -> PiSubagentPhase {
        switch turn?["status"]?.string {
        case "completed": .done
        case "failed": .failed
        default: .interrupted
        }
    }

    /// 子代理落定：父线程这一轮在跑，结果并进这一轮；歇着就等这一批都落定再补一轮。已经落定的（一轮结束后又卸载）不再算。
    private func settle(_ child: String, _ phase: PiSubagentPhase, summary: String?, in session: Tracked) {
        guard session.facts.inFlight.contains(child), session.unread[child] == nil else { return }
        session.facts.settleSubagent(child, phase, summary: summary, at: .now)
        session.lastWords[child] = nil
        if session.facts.running {
            session.facts.inFlight.remove(child)
        } else {
            session.unread[child] = phase != .interrupted
            wake(session)
        }
    }

    /// 最后一个在跑的子代理落定、父线程歇着：补一轮空输入，这一轮发出就算开始，它做完才歇下。空输入的一轮先把子代理的结果取进来再请求模型；
    /// 带文字的一轮先请求模型，v2 的结果要到之后才取出，模型会答"还没收到"。
    /// 同 Codex 的 `wake_on_agent_messages`（openai/codex#54961，未发布、默认关、不管 v1，发布并默认开启后改用它），边界也照它：
    /// 父线程上一轮被停下、在 Plan 模式、这一批没有交回结果（都被停下）的不补，直接歇下。补的这一轮在跑时你说话，照常先停下它再开你那一轮（`deliver`）。
/// 终端里这一轮显示为一段没有提问的回答；它不触发 `UserPromptSubmit`，输入框里打了一半的话不受影响（实测）。
    private func wake(_ session: Tracked) {
        let batch = session.facts.inFlight
        guard !session.facts.running, batch == Set(session.unread.keys) else { return }
        let delivered = session.unread.values.contains(true)
        let file = bridge.session(id: session.id)?.sessionFile
        Task {
            var last: CodexHistory.LastTurn?
            if delivered, let file { last = await CodexHistory.lastTurn(in: file) }
            guard tracked[session.id] === session, !session.facts.running, session.facts.inFlight == batch else { return }
            session.unread = [:]
            session.facts.inFlight = []
            guard delivered, last?.plan != true, last?.interrupted != true else { return publish(session) }
            startTurn(session, at: .now)
            publish(session)
            do {
                try await control(session).call("turn/start", ["threadId": .string(session.threadID), "input": []])
            } catch {
                guard tracked[session.id] === session, session.facts.running else { return }
                session.facts.endTurn(failure: error.localizedDescription)
                publish(session)
            }
        }
    }

    // MARK: 命令（`SessionLink`）

    public func send(_ message: PiMessage, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        try await deliver(CodexRPC.input(text: message.text, images: message.images), clientID: CodexHistory.clientID(for: message.deliveryID), to: session)
    }

    /// 以这句开新一轮：在跑就先停下这一轮。`turn/interrupt` 等这一轮真的中止了才回（实测 0.162.1：回应与 `turn/completed` 的
    /// `interrupted` 同时到），所以紧接着的 `turn/start` 开的是新一轮——它碰上还在跑的一轮会变成插话（压缩那一轮则拒收）。
    /// 被停下的那一轮不报歇下（`restarting`）：这句开出新一轮就从此刻算起，没开成才歇下。
    private func deliver(_ input: [JSONValue], clientID: String, to session: Tracked) async throws {
        session.restarting = .stopping
        defer { session.restarting = nil }
        do {
            try await interrupt(session)
            try await call(session, "turn/start", ["threadId": .string(session.threadID), "clientUserMessageId": .string(clientID), "input": .array(input)])
        } catch {
            if session.restarting == .stopped { session.facts.endTurn() }
            publish(session)
            throw error
        }
        guard session.restarting == .stopped else { return }
        startTurn(session, at: .now)
        publish(session)
    }

    public func command(_ line: String, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        let name = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "compact":
            try await call(session, "thread/compact/start", ["threadId": .string(session.threadID)])
        case "name":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: nil, thinking: nil, name: argument, in: id)
        case "model":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: PiModelKey(provider: CodexModel.provider, id: argument), thinking: nil, name: nil, in: id)
        case "plan", "default":
            guard hosted[session.pid] != nil else { throw PiBridgeError.rejected("unknown_command") }
            try await collaborate(name == "plan" ? "plan" : "default", in: session)
            if !argument.isEmpty {
                try await deliver(CodexRPC.input(text: argument, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            }
        case _ where name.hasPrefix("skill:"):
            guard let skill = session.skills.first(where: { "skill:\($0.name)" == name }) else { throw PiBridgeError.rejected("unknown_command") }
            var input: [JSONValue] = [["type": "skill", "name": .string(skill.name), "path": .string(skill.path)]]
            input += CodexRPC.input(text: argument, images: [])
            try await deliver(input, clientID: CodexHistory.clientID(for: nil), to: session)
        default:
            throw PiBridgeError.rejected("unknown_command")
        }
    }

    /// 之后的轮次用的协作模式（实验接口）：模型与强度照会话此刻的，说明用这个模式内置的。
    private func collaborate(_ mode: String, in session: Tracked) async throws {
        let current = bridge.session(id: session.id)
        guard let model = current?.model?.key.id else { throw PiBridgeError.rejected("failed: 不知道这个会话用的模型") }
        var settings: [String: JSONValue] = ["model": .string(model), "developer_instructions": .null]
        if case .known(let level)? = current?.thinking { settings["reasoning_effort"] = .string(CodexModel.effort(level)) }
        try await call(session, "thread/settings/update", [
            "threadId": .string(session.threadID), "collaborationMode": ["mode": .string(mode), "settings": .object(settings)],
        ])
    }

    public func abort(_ id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        try await interrupt(session)
    }

    /// 停下 Codex 此刻在跑的那一轮（含压缩那一轮）；歇着什么都不做。在不在跑、是哪一轮只问 Codex（最近一轮），不另记这一轮的 id：
    /// 钩子推出的忙闲只给界面看，不拿来判断要不要停。
    private func interrupt(_ session: Tracked) async throws {
        let thread = JSONValue.string(session.threadID)
        do {
            let rpc = try await control(session)
            let latest = try await Self.lastTurn(session.threadID, on: rpc)
            guard latest?["status"]?.string == "inProgress", let turn = latest?["id"] else { return }
            try await rpc.call("turn/interrupt", ["threadId": thread, "turnId": turn])
        } catch CodexRPCError.server(-32600, _) {
            // 这一轮在问与停之间自己结束了（"no active turn to interrupt"）：要的就是它不在跑
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
    }

    /// 改名走 `thread/name/set`；模型与强度走 `thread/settings/update`，强度按新模型支持的范围夹取（`PiThinkingLevel.clamped`）。
    public func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        if let name {
            try await call(session, "thread/name/set", ["threadId": .string(session.threadID), "name": .string(name)])
            bridge.update(id) { $0.name = name }
        }
        guard model != nil || thinking != nil else { return }
        let rpc = try await control(session)
        if models == nil { models = try await CodexModel.list(rpc) }
        let target = model?.id ?? bridge.session(id: id)?.model?.key.id
        let entry = models?.first { $0.id == target }
        if model != nil, entry == nil { throw PiBridgeError.unknownModel(.codex) }
        var settings: [String: JSONValue] = ["threadId": .string(session.threadID)]
        if let model { settings["model"] = .string(model.id) }
        if let thinking { settings["effort"] = .string(CodexModel.effort(thinking.clamped(to: entry?.efforts ?? []))) }
        try await call(session, "thread/settings/update", .object(settings))
        if let thread = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])["thread"] {
            bridge.update(id) { self.apply(thread, to: &$0) }
        }
    }

    /// 托管的会话关掉进程（app-server 读到 EOF 收尾退出）；终端里的会话 Codex 没有让终端退出的接口（能力表里没有，桥先拒绝）。
    public func end(_ id: PiSession.ID) throws {
        guard let session = tracked[id], let rpc = hosted[session.pid] else { throw PiBridgeError.unsupported }
        rpc.close()
    }

    private func call(_ session: Tracked, _ method: String, _ params: JSONValue) async throws {
        do {
            try await control(session).call(method, params)
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
    }
}

/// `model/list` 里的一个模型：强度是 Codex 的 `ReasoningEffort`（`none` 即关闭；`ultra` 等 CuePad 没有的档丢掉）。
struct CodexModel {
    let id: String
    let name: String
    let efforts: [PiThinkingLevel]
    /// 能看图（`inputModalities` 里有 image）
    let seesImages: Bool
    /// 用户没配模型时 Codex 用的那个
    let isDefault: Bool

    /// 模型的提供方写成 Codex 自己（`AgentKind.modelProvider`），不用线程上的 `modelProvider`（openai 等）：Codex 的模型 id 在它自己的命名空间里。
    static let provider = AgentKind.codex.modelProvider!

    var option: PiModelOption {
        PiModelOption(key: PiModelKey(provider: Self.provider, id: id), name: name, thinkingLevels: efforts, acceptsImages: seesImages)
    }

    static func thinking(_ effort: String) -> Open<PiThinkingLevel> { Open(rawValue: effort == "none" ? "off" : effort) }
    static func effort(_ level: PiThinkingLevel) -> String { level == .off ? "none" : level.rawValue }

    /// 失败的一轮（`turn/completed` 的 `status` 为 failed）的原因：`turn.error` 的说明，带上补充细节。
    static func failure(of turn: JSONValue?) -> String {
        let message = [turn?["error"]?["message"]?.string, turn?["error"]?["additionalDetails"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
        return message.isEmpty ? "Codex 这一轮失败了" : message.joined(separator: "\n")
    }

    /// `hidden`：连隐藏的模型也要（大脑可能配的就是它）。
    @MainActor static func list(_ rpc: CodexRPC, hidden: Bool = false) async throws -> [CodexModel] {
        let listed = try await rpc.call("model/list", hidden ? ["includeHidden": true, "limit": 500] : [:])
        return (listed["data"]?.array ?? []).compactMap { entry in
            guard hidden || entry["hidden"]?.bool != true, let id = entry["id"]?.string else { return nil }
            let efforts = (entry["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
            // 没写 inputModalities 的按协议缺省（文字与图片）
            let seesImages = entry["inputModalities"]?.array.map { $0.contains("image") } ?? true
            return CodexModel(
                id: id, name: entry["displayName"]?.string ?? id, efforts: efforts.compactMap { thinking($0).known }, seesImages: seesImages,
                isDefault: entry["isDefault"]?.bool == true)
        }
    }
}
#endif

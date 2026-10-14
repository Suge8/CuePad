#if os(macOS)
import CueStore
import Foundation
import OSLog

/// Codex 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它常驻服务的控制 socket 说话；后台托管的会话是 CuePad 起的 `codex app-server`。
///
/// - 状态只来自钩子（托管的会话也一样，钩子在承载线程的进程里跑）：提交一句话进入工作，调工具、等权限确认、压缩、子代理随事件更新，
///   `Stop`/`Interrupt` 歇下，`SessionEnd` 下线。会话 id 是线程 id，承载进程是钩子的父进程（终端会话是常驻服务，托管的是 CuePad 起的进程）。
///   承载进程退出时它上面的会话都下线。常驻服务里的线程在终端退出后还会挂着（没有订阅者、闲置 30 分钟才卸载并报 `SessionEnd`），
///   这段时间它仍在线、能收话，这是 Codex 的语义。
/// - 控制只经 app-server 的接口，不为观察而订阅（`thread/resume` 会把终端的事件与审批抢走）：说话是 `turn/steer`（马上说，
///   插进在跑的这一轮）与 `thread/queue/add`（等它做完再说，空闲时立刻开始），停止是 `turn/interrupt`，换模型与强度是
///   `thread/settings/update`，改名是 `thread/name/set`，斜杠命令只有映射得上的几个。常驻服务把 `thread/status/changed`、
///   `thread/name/updated`、`thread/closed` 广播给所有连接：钩子漏掉的歇下（出错时没有 `Stop`）与改名靠它们补上。
/// - 权限确认经 `PermissionRequest` 钩子：Codex 先问钩子、钩子没给决定才在终端里弹框。终端会话按人在不在（`UserPresence`）分：
///   人在就当场放行钩子，终端弹框，CuePad 里的问题只能在终端里答；人不在就挂住钩子等 CuePad 作答（终端里只显示钩子的状态行
///   `CodexHooks.waitingMessage`），挂住期间人回来了就放行、终端补弹。托管的会话没有终端，总是挂住。在终端里按 Esc 停下这一轮
///   会收回挂住的调用。Plan 模式的提问只发给订阅者（终端界面），CuePad 只显示、在终端里答；CuePad 开的会话不进 Plan 模式。
@MainActor
public final class CodexRuntime: AgentRuntime {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "codex")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    private let locator: ExecutableLocator
    private let presence: any UserPresence
    /// 有挂住的终端会话确认时等人回来
    private var returnWatch: Task<Void, Never>?
    private let idleLimit: Duration
    private let launchTimeout: Duration
    private var tracked: [PiSession.ID: Tracked] = [:]
    /// CuePad 托管的进程（进程号 → 进程）
    private var hosted: [Int32: CodexRPC] = [:]
    private var idleTimers: [Int32: Task<Void, Never>] = [:]
    private var daemon: CodexRPC?
    private var connecting: Task<CodexRPC, any Error>?
    private var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    private var models: [CodexModel]?
    private var stopped = true

    /// - Parameter idleLimit: 托管的会话歇着满这么久就关掉进程（不算结束，发话时再接着）。
    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, locator: ExecutableLocator = .standard,
        presence: any UserPresence = SystemPresence(), idleLimit: Duration = .seconds(30 * 60), launchTimeout: Duration = .seconds(30)
    ) {
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locator = locator
        self.presence = presence
        self.idleLimit = idleLimit
        self.launchTimeout = launchTimeout
    }

    /// 一个在线会话在这里的状态（快照在桥上）。
    private final class Tracked {
        let id: PiSession.ID
        let threadID: String
        let pid: Int32
        /// 这一轮的 id（`turn/steer`、`turn/interrupt` 要它）与是否在跑
        var turnID: String?
        var turnRunning = false
        var question: Question? { didSet { onQuestion?() } }
        var onQuestion: (() -> Void)?
        /// 发起的子代理的任务名，等 `SubagentStart` 认领（按先后）
        var spawnNames: [String] = []
        /// 歇着时手动压缩：压完回到压缩前的状态与起点
        var beforeCompact: (state: PiWorkState, since: Date, busySince: Date?)?
        var skills: [(name: String, path: String)] = []

        init(id: PiSession.ID, threadID: String, pid: Int32) {
            self.id = id
            self.threadID = threadID
            self.pid = pid
        }
    }

    /// 等你回答的问题与怎么回给 Codex。
    private struct Question {
        let question: PiQuestion
        let reply: Reply

        enum Reply {
            /// 阻塞着的 `PermissionRequest` 钩子
            case hook(AgentHookCall)
            /// Plan 模式的提问：只有订阅者（终端界面）收得到，只能在终端里答
            case terminal
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
        guard FileManager.default.fileExists(atPath: controlSocket) else { return }
        Task { await discover() }
    }

    public func stop() -> @concurrent @Sendable () async -> Void {
        stopped = true
        for session in tracked.values {
            if case .hook(let call) = session.question?.reply { call.finish() }
        }
        returnWatch?.cancel()
        returnWatch = nil
        for timer in idleTimers.values { timer.cancel() }
        idleTimers = [:]
        for watcher in exitWatchers.values { watcher.cancel() }
        exitWatchers = [:]
        daemon?.close()
        daemon = nil
        let processes = Array(hosted.values)
        let waits = processes.map { rpc in Task { await rpc.shutdown() } }
        return { for wait in waits { await wait.value } }
    }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        try await withLaunchTimeout { rpc in
            let started = try await rpc.call("thread/start", ["cwd": directory.path])
            return self.attachHosted(started, rpc: rpc, launchToken: launchToken)
        }
    }

    /// 接着一个已结束的会话：还在常驻服务里（终端开着它，或终端退出后它还挂着）就经控制 socket 接上，不另开一份；
    /// 否则在后台起进程恢复它。恢复时它被别处拿着写（终端里刚开）也改走控制 socket；常驻服务里也没有它才报错。
    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: session.id) { return live.id }
        if let id = try await adoptFromDaemon(session.id) { return id }
        do {
            return try await withLaunchTimeout { rpc in
                let resumed = try await rpc.call("thread/resume", ["threadId": session.id, "path": session.path, "excludeTurns": true])
                return self.attachHosted(resumed, rpc: rpc, launchToken: nil)
            }
        } catch CodexRPCError.server(_, let message) where message.contains("active writer") {
            if let id = try await adoptFromDaemon(session.id) { return id }
            throw AgentRuntimeError.openElsewhere
        }
    }

    /// 托管的会话关掉进程并等它下线；终端里的会话 CuePad 结束不了（Codex 没有让终端退出的接口）。
    public func end(_ id: PiSession.ID) async throws {
        guard let session = tracked[id] else { return }
        guard let rpc = hosted[session.pid] else { throw PiBridgeError.unsupported }
        await rpc.shutdown()
    }

    // MARK: 托管进程

    private var controlSocket: String {
        paths.home(of: .codex).appending(path: "app-server-control/app-server-control.sock").path
    }

    /// 托管进程的环境：`AgentPaths` 的环境（App 里是自己的环境，隔离测试里指到临时目录），配置目录与钩子 socket 目录照它定。
    private var codexEnvironment: [String: String] {
        paths.environment.merging([
            "CODEX_HOME": paths.home(of: .codex).path,
            "CUEPAD_PI_SOCKET_DIR": paths.pi.socketDirectory.path,
            "PATH": locator.searchDirectories.map(\.path).joined(separator: ":"),
        ]) { $1 }
    }

    /// 起一个托管进程交给 `body`；超过 `launchTimeout` 停掉进程（等着的请求随之失败），出错时也停掉。握手由 `CodexRPC.launch` 自己限时。
    private func withLaunchTimeout(_ body: @MainActor (CodexRPC) async throws -> PiSession.ID) async throws -> PiSession.ID {
        guard let codex = locator.candidates(AgentKind.codex.command).first else { throw AgentRuntimeError.notInstalled(.codex) }
        let launched = Launched()
        let timeout = launchTimeout
        let timer = Task { [launched] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            launched.timedOut = true
            launched.rpc?.terminate()
        }
        defer { timer.cancel() }
        do {
            let rpc = try await CodexRPC.launch(codex, environment: codexEnvironment)
            launched.rpc = rpc
            host(rpc)
            guard !launched.timedOut else { throw AgentRuntimeError.launchTimedOut(.codex) }
            return try await body(rpc)
        } catch {
            if let rpc = launched.rpc { await rpc.shutdown() }
            throw launched.timedOut || error as? CodexRPCError == .timedOut ? AgentRuntimeError.launchTimedOut(.codex) : error
        }
    }

    @MainActor private final class Launched {
        var rpc: CodexRPC?
        var timedOut = false
    }

    private func host(_ rpc: CodexRPC) {
        let pid = rpc.pid
        hosted[pid] = rpc
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        rpc.onClose = { [weak self] in self?.processGone(pid) }
    }

    private func attachHosted(_ result: CodexRPC.Object, rpc: CodexRPC, launchToken: String?) -> PiSession.ID {
        let thread = result["thread"] as? CodexRPC.Object ?? [:]
        var session = makeSession(thread, pid: rpc.pid)
        session.hosted = true
        session.launchToken = launchToken
        attach(session)
        idle(rpc.pid)
        return session.id
    }

    /// 托管的会话歇下就开始计时，满 `idleLimit` 关掉进程；有活就停表。
    private func idle(_ pid: Int32) {
        idleTimers.removeValue(forKey: pid)?.cancel()
        guard let rpc = hosted[pid], !tracked.values.contains(where: { $0.pid == pid && (bridge.session(id: $0.id)?.state.hasPendingWork ?? false) })
        else { return }
        let limit = idleLimit
        idleTimers[pid] = Task { [weak rpc] in
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            rpc?.close()
        }
    }

    // MARK: 常驻服务

    /// 连上常驻服务（已连着就用那条）。
    private func daemonConnection() async throws -> CodexRPC {
        if let daemon, !daemon.isClosed { return daemon }
        if let connecting { return try await connecting.value }
        let task = Task { try await CodexRPC.connect(socket: controlSocket) }
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

    /// 启动时把常驻服务里已经载入的线程接上（CuePad 晚于终端里的会话启动）。子代理的线程不算会话。
    private func discover() async {
        do {
            let rpc = try await daemonConnection()
            let loaded = try await rpc.call("thread/loaded/list", [:])
            for threadID in loaded["data"] as? [String] ?? [] where tracked["\(threadID).\(rpc.pid)"] == nil {
                _ = try await adopt(threadID, on: rpc)
            }
        } catch {
            Self.log.notice("没能读出常驻服务里的会话：\(String(describing: error))")
        }
    }

    private func adoptFromDaemon(_ threadID: String) async throws -> PiSession.ID? {
        guard FileManager.default.fileExists(atPath: controlSocket), let rpc = try? await daemonConnection() else { return nil }
        let loaded = try await rpc.call("thread/loaded/list", [:])
        guard (loaded["data"] as? [String] ?? []).contains(threadID) else { return nil }
        return try await adopt(threadID, on: rpc)
    }

    @discardableResult
    private func adopt(_ threadID: String, on rpc: CodexRPC) async throws -> PiSession.ID? {
        let id = "\(threadID).\(rpc.pid)"
        if tracked[id] != nil { return id }
        let read = try await rpc.call("thread/read", ["threadId": threadID])
        guard let thread = read["thread"] as? CodexRPC.Object, thread["parentThreadId"] is NSNull || thread["parentThreadId"] == nil else { return nil }
        if tracked[id] != nil { return id }
        var session = makeSession(thread, pid: rpc.pid)
        // 正在跑一轮：停止、插话要这一轮的 id，从最近一轮取（钩子要等下一个事件才带来）
        var running: String?
        if (thread["status"] as? CodexRPC.Object)?["type"] as? String == "active" {
            let turns = try await rpc.call("thread/turns/list", ["threadId": threadID, "limit": 1])
            running = ((turns["data"] as? [CodexRPC.Object])?.first).flatMap { $0["status"] as? String == "inProgress" ? $0["id"] as? String : nil }
        }
        if tracked[id] != nil { return id }
        if running != nil { Self.move(&session, to: .thinking) }
        attach(session)
        tracked[id]?.turnID = running
        tracked[id]?.turnRunning = running != nil
        return id
    }

    // MARK: 会话

    private func makeSession(_ thread: CodexRPC.Object, pid: Int32) -> PiSession {
        let threadID = thread["id"] as? String ?? ""
        var session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: (thread["path"] as? String).map { URL(filePath: $0) },
            pid: pid, cwd: URL(filePath: thread["cwd"] as? String ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            extensionVersion: 0, state: .settled, stateSince: .now)
        apply(thread, to: &session)
        return session
    }

    /// 线程的名字、首条消息、模型与强度写进快照（`thread/read`、`thread/start`、`thread/resume` 给的都是这个形状）。
    private func apply(_ thread: CodexRPC.Object, to session: inout PiSession) {
        session.name = thread["name"] as? String
        if let preview = thread["preview"] as? String, !preview.isEmpty { session.firstMessage = String(preview.prefix(PiSessionName.firstMessageLimit)) }
        if let model = thread["model"] as? String {
            let provider = thread["modelProvider"] as? String ?? "openai"
            session.model = models?.first { $0.id == model }.map { $0.option(provider: provider) }
                ?? PiModelOption(key: PiModelKey(provider: provider, id: model), name: model, thinkingLevels: [])
            session.availableModels = (models ?? []).map { $0.option(provider: provider) }
        }
        session.thinking = (thread["reasoningEffort"] as? String).map(CodexModel.thinking)
    }

    private func attach(_ session: PiSession) {
        let entry = Tracked(id: session.id, threadID: session.sessionID, pid: session.pid)
        entry.onQuestion = { [weak self] in self?.watchReturn() }
        tracked[session.id] = entry
        bridge.attach(session, via: CodexLink(runtime: self, id: session.id))
        watchExit(session.pid)
        refresh(session.id, skills: true)
    }

    private func watchExit(_ pid: Int32) {
        guard exitWatchers[pid] == nil else { return }
        exitWatchers[pid] = ProcessExitWatcher(pid: pid) { [weak self] in
            Task { @MainActor in self?.processGone(pid) }
        }
    }

    /// 承载进程退出了：它上面的会话都下线。
    private func processGone(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        idleTimers.removeValue(forKey: pid)?.cancel()
        hosted[pid] = nil
        for session in tracked.values where session.pid == pid { detach(session.id, reason: .closed(reason: "quit")) }
    }

    private func detach(_ id: PiSession.ID, reason: PiSessionEndReason) {
        guard let session = tracked.removeValue(forKey: id) else { return }
        if case .hook(let call) = session.question?.reply { call.finish() }
        bridge.detach(id, reason: reason)
        watchReturn()
    }

    /// 从 Codex 重新读名字、模型与强度（`thread/read`），可换的模型（`model/list`）与 skill（`skills/list`，斜杠命令）。
    private func refresh(_ id: PiSession.ID, skills: Bool = false) {
        Task {
            do {
                guard let session = tracked[id] else { return }
                let rpc = try await control(session)
                if models == nil { models = try await CodexModel.list(rpc) }
                if skills, let cwd = bridge.session(id: id)?.cwd {
                    let listed = try await rpc.call("skills/list", ["cwds": [cwd.path]])
                    let entries = ((listed["data"] as? [CodexRPC.Object])?.first?["skills"] as? [CodexRPC.Object]) ?? []
                    session.skills = entries.compactMap { entry in
                        guard entry["enabled"] as? Bool != false, let name = entry["name"] as? String, let path = entry["path"] as? String else { return nil }
                        return (name, path)
                    }
                    let commands = Self.builtinCommands + entries.compactMap { entry -> PiSlashCommand? in
                        guard entry["enabled"] as? Bool != false, let name = entry["name"] as? String else { return nil }
                        return PiSlashCommand(
                            name: "skill:\(name)", summary: (entry["description"] as? String).map { String($0.prefix(120)) }, source: .known(.skill))
                    }
                    bridge.update(id) { $0.commands = commands }
                }
                let read = try await rpc.call("thread/read", ["threadId": session.threadID])
                guard let thread = read["thread"] as? CodexRPC.Object else { return }
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

    /// 会话的控制通道：托管的是它的进程，终端里的是常驻服务（钩子的父进程就是它才算；`codex exec` 之类没有控制接口）。
    private func control(_ session: Tracked) async throws -> CodexRPC {
        if let rpc = hosted[session.pid] { return rpc }
        guard FileManager.default.fileExists(atPath: controlSocket) else { throw PiBridgeError.unsupported }
        let rpc = try await daemonConnection()
        guard rpc.pid == session.pid else { throw PiBridgeError.unsupported }
        return rpc
    }

    private func change(_ id: PiSession.ID, _ body: (inout PiSession) -> Void) {
        bridge.update(id, body)
        if let pid = tracked[id]?.pid, hosted[pid] != nil { idle(pid) }
    }

    /// 换到 `state`：粗状态（工作中、等你确认、出错、空闲）变了才换起点；离开空闲时开始计"连续处理"，回到空闲或出错时清掉。
    private static func move(_ session: inout PiSession, to state: PiWorkState, detail: String? = nil, at now: Date = .now) {
        func phase(_ state: PiWorkState) -> Int { state.isWorking ? 0 : state == .waitingForUser ? 1 : state == .error ? 2 : 3 }
        if phase(session.state) != phase(state) { session.stateSince = now }
        if state.hasPendingWork { session.busySince = session.busySince ?? now } else { session.busySince = nil }
        session.state = state
        session.detail = detail
        if state != .waitingForUser { session.question = nil }
    }

    // MARK: 钩子

    private func hook(_ call: AgentHookCall) {
        guard let input = (try? JSONSerialization.jsonObject(with: call.envelope.input)) as? CodexRPC.Object,
              let event = input["hook_event_name"] as? String, let threadID = input["session_id"] as? String
        else { return call.finish() }
        let id = "\(threadID).\(call.envelope.pid)"
        if event == "SessionEnd" {
            call.finish()
            return detach(id, reason: .closed(reason: "quit"))
        }
        let session = tracked[id] ?? adoptFromHook(threadID, pid: call.envelope.pid, input)
        if let turn = input["turn_id"] as? String, input["agent_id"] == nil { session.turnID = turn }
        switch event {
        case "PermissionRequest":
            // 子代理要的确认也挂在这个会话上问
            ask(session, call: call, input)
            return
        case "SubagentStart", "SubagentStop":
            subagent(session, event, input)
        case _ where input["agent_id"] != nil:
            // 子代理自己线程里的事件（session_id 是同一棵树的根，agent_id 是它自己）：只更新它在做什么
            if event == "PreToolUse", let name = (input["agent_id"] as? String).flatMap({ subagentNames[$0] }) {
                change(id) { s in
                    if let index = s.subagents.lastIndex(where: { $0.name == name }) { s.subagents[index].action = Self.toolDetail(input) ?? "" }
                }
            }
        default:
            turn(session, event, input)
        }
        call.finish()
    }

    /// 钩子先于其他途径报出的会话（终端里刚开、或 CuePad 晚启动）：接上桥，名字与模型随后从 Codex 读。
    private func adoptFromHook(_ threadID: String, pid: Int32, _ input: CodexRPC.Object) -> Tracked {
        let session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: (input["transcript_path"] as? String).map { URL(filePath: $0) },
            pid: pid, cwd: URL(filePath: input["cwd"] as? String ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            extensionVersion: 0, state: .settled, stateSince: .now)
        attach(session)
        return tracked[session.id]!
    }

    private func turn(_ session: Tracked, _ event: String, _ input: CodexRPC.Object) {
        let id = session.id
        switch event {
        case "UserPromptSubmit":
            session.turnRunning = true
            change(id) { s in
                if s.firstMessage == nil, let prompt = input["prompt"] as? String, !prompt.isEmpty {
                    s.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
                }
                Self.move(&s, to: .thinking)
            }
            refresh(id)
        case "PreToolUse":
            if (input["tool_name"] as? String)?.hasSuffix("spawn_agent") == true,
               let name = (input["tool_input"] as? CodexRPC.Object)?["task_name"] as? String {
                session.spawnNames.append(name)
            }
            if input["tool_name"] as? String == "request_user_input" {
                let question = Self.userInput(input["tool_input"] as? CodexRPC.Object ?? [:], promptID: nil)
                session.question = Question(question: question, reply: .terminal)
                change(id) { Self.move(&$0, to: .waitingForUser, detail: question.text.components(separatedBy: "\n").first); $0.question = question }
                return
            }
            change(id) { Self.move(&$0, to: .tool, detail: Self.toolDetail(input)) }
        case "PostToolUse":
            if case .terminal = session.question?.reply { session.question = nil }
            guard session.question == nil else { return }
            change(id) { Self.move(&$0, to: .thinking) }
        case "PreCompact":
            if !session.turnRunning, let s = bridge.session(id: id) { session.beforeCompact = (s.state, s.stateSince, s.busySince) }
            change(id) { Self.move(&$0, to: .compacting, detail: nil) }
        case "PostCompact":
            if let before = session.beforeCompact {
                session.beforeCompact = nil
                change(id) { s in
                    s.state = before.state
                    s.stateSince = before.since
                    s.busySince = before.busySince
                    s.detail = nil
                }
            } else {
                change(id) { Self.move(&$0, to: .thinking) }
            }
        case "Stop", "Interrupt":
            settle(session)
            refresh(id)
        default:
            break
        }
    }

    /// 这一轮结束：还有子代理在跑是等子代理，否则歇下。
    private func settle(_ session: Tracked) {
        session.turnRunning = false
        session.beforeCompact = nil
        if case .hook(let call) = session.question?.reply { call.finish() }
        session.question = nil
        change(session.id) { s in
            Self.move(&s, to: s.subagents.contains { $0.phase == .known(.running) } ? .delegating : .settled)
        }
    }

    private func subagent(_ session: Tracked, _ event: String, _ input: CodexRPC.Object) {
        guard let agent = input["agent_id"] as? String else { return }
        let role = input["agent_type"] as? String ?? "default"
        let now = Date.now
        if event == "SubagentStart" {
            let name = session.spawnNames.isEmpty ? role : session.spawnNames.removeFirst()
            change(session.id) { $0.subagents.append(PiSubagentState(name: name, role: role, phase: .known(.running), startedAt: now)) }
            subagentNames[agent] = name
            return
        }
        let name = subagentNames.removeValue(forKey: agent) ?? role
        let reply = (input["last_assistant_message"] as? String)?.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
        change(session.id) { s in
            if let index = s.subagents.lastIndex(where: { $0.name == name && $0.phase == .known(.running) }) {
                s.subagents[index].phase = .known(.done)
                s.subagents[index].action = reply
                s.subagents[index].settledAt = now
            }
            if s.state == .delegating, !s.subagents.contains(where: { $0.phase == .known(.running) }) { Self.move(&s, to: .settled) }
        }
    }

    /// 子代理线程 id → 名册里的名字
    private var subagentNames: [String: String] = [:]

    /// 工具名 · 调用摘要（命令、搜索取首个非空行，文件取文件名），至多 120 字符。
    private static func toolDetail(_ input: CodexRPC.Object) -> String? {
        guard let tool = input["tool_name"] as? String else { return nil }
        let arguments = input["tool_input"] as? CodexRPC.Object ?? [:]
        let summary = (arguments["command"] as? String ?? arguments["pattern"] as? String ?? arguments["query"] as? String)
            .flatMap { $0.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } }
            ?? (arguments["path"] as? String ?? arguments["file_path"] as? String).map { URL(filePath: $0).lastPathComponent }
        let detail = summary.map { "\(tool) · \($0)" } ?? tool
        return detail.count <= 120 ? detail : String(detail.prefix(119)) + "…"
    }

    // MARK: 等你回答

    /// 权限确认：终端会话的人在这台 Mac 前就交给终端；否则钩子拿着，等 CuePad 作答，钩子先走了（终端里停下了这一轮）就收起问题。
    private func ask(_ session: Tracked, call: AgentHookCall, _ input: CodexRPC.Object) {
        let arguments = input["tool_input"] as? CodexRPC.Object ?? [:]
        let action = (arguments["command"] as? String).map { "Codex 想运行：\($0)" } ?? "Codex 想用 \(input["tool_name"] as? String ?? "工具")"
        let text = String([action, arguments["description"] as? String].compactMap { $0 }.joined(separator: "\n").prefix(500))
        if hosted[session.pid] == nil, presence.isPresent {
            call.finish()
            return handBack(session, text)
        }
        present(session, PiQuestion(promptID: UUID().uuidString, kind: .confirm, text: text), reply: .hook(call))
        call.onClose = { [weak self, weak session] in
            guard let self, let session, case .hook(let held) = session.question?.reply, held === call else { return }
            self.withdraw(session)
        }
    }

    /// 确认交给终端：钩子不给决定（挂着的由 `present` 放行），Codex 在终端里弹框；CuePad 里还显示，只能在终端里答。
    private func handBack(_ session: Tracked, _ text: String) {
        present(session, PiQuestion(promptID: nil, kind: .confirm, text: text), reply: .terminal)
    }

    /// 有终端会话的确认挂着才等人回来，回来了全部交给终端；没有挂着的就停下等待。
    private func watchReturn() {
        let held = tracked.values.contains { session in
            guard case .hook = session.question?.reply else { return false }
            return hosted[session.pid] == nil
        }
        guard held else {
            returnWatch?.cancel()
            returnWatch = nil
            return
        }
        guard returnWatch == nil else { return }
        returnWatch = Task { [weak self, presence] in
            await presence.untilPresent()
            guard let self, !Task.isCancelled else { return }
            for session in self.tracked.values where self.hosted[session.pid] == nil {
                guard let pending = session.question, case .hook = pending.reply else { continue }
                self.handBack(session, pending.question.text)
            }
            self.returnWatch = nil
        }
    }

    private func present(_ session: Tracked, _ question: PiQuestion, reply: Question.Reply) {
        if case .hook(let call) = session.question?.reply { call.finish() }
        session.question = Question(question: question, reply: reply)
        change(session.id) { s in
            Self.move(&s, to: .waitingForUser, detail: question.text.components(separatedBy: "\n").first)
            s.question = question
        }
    }

    /// 问题收起了（答过、被收回）：回到工作中。
    private func withdraw(_ session: Tracked) {
        session.question = nil
        change(session.id) { s in
            guard s.state == .waitingForUser else { return }
            Self.move(&s, to: session.turnRunning ? .thinking : .settled)
        }
    }

    /// Plan 模式的提问（`request_user_input` 的参数，一次可能几个，显示第一个）：有选项是单选，否则填文字；标题与问题换行连接。
    private static func userInput(_ arguments: CodexRPC.Object, promptID: String?) -> PiQuestion {
        let first = (arguments["questions"] as? [CodexRPC.Object])?.first ?? [:]
        let text = [first["header"] as? String, first["question"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let options = (first["options"] as? [CodexRPC.Object] ?? []).compactMap { $0["label"] as? String }
        return PiQuestion(promptID: promptID, kind: options.isEmpty ? .text : .select, text: String(text.prefix(500)), options: options)
    }

    /// 权限确认的回答写回钩子（允许或拒绝，附一句给模型看的原因）。
    fileprivate func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) throws {
        guard let session = tracked[id], let pending = session.question, case .hook(let call) = pending.reply else {
            throw PiBridgeError.rejected("no_prompt")
        }
        guard pending.question.promptID == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        guard case .confirmed(let allowed) = answer else { throw PiBridgeError.rejected("bad_answer") }
        let decision: CodexRPC.Object = ["behavior": allowed ? "allow" : "deny", "message": allowed ? "在 CuePad 里允许了" : "在 CuePad 里拒绝了"]
        call.reply(try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]))
        withdraw(session)
    }

    // MARK: 通知

    private func notification(_ method: String, _ params: CodexRPC.Object, from pid: Int32) {
        guard let threadID = params["threadId"] as? String else { return }
        let id = "\(threadID).\(pid)"
        guard let session = tracked[id] else { return }
        switch method {
        case "thread/name/updated":
            change(id) { $0.name = params["threadName"] as? String }
        case "thread/status/changed":
            switch (params["status"] as? CodexRPC.Object)?["type"] as? String {
            // 钩子漏报的歇下（出错的一轮没有 Stop）；钩子的 Stop 晚到也只是再歇一次
            case "idle" where session.turnRunning: settle(session)
            case "systemError":
                session.turnRunning = false
                change(id) { Self.move(&$0, to: .error, detail: "Codex 出错了") }
            default: break
            }
        case "thread/closed":
            detach(id, reason: .closed(reason: "quit"))
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? CodexRPC.Object, let window = usage["modelContextWindow"] as? Int else { return }
            let used = (usage["last"] as? CodexRPC.Object)?["totalTokens"] as? Int
            change(id) { $0.context = PiContextUsage(tokens: used, window: window) }
        default:
            break
        }
    }

    // MARK: 命令（`CodexLink` 转来）

    fileprivate func send(_ message: PiMessage, in id: PiSession.ID) async throws -> PiDelivery {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        var input: [CodexRPC.Object] = message.text.isEmpty ? [] : [["type": "text", "text": message.text, "text_elements": []]]
        input += message.images.map { ["type": "image", "url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())"] }
        return try await deliver(input, clientID: CodexHistory.clientID(for: message.deliveryID), whenBusy: message.whenBusy, to: session)
    }

    /// 马上说：插进在跑的这一轮；刚好歇下（没有这一轮了）就排进队列。等它做完再说、空闲时都进队列，空闲时再让队列里的这一条开始：
    /// 停下一轮之后 Codex 不自动接着跑队列（终端里的界面会自己开始，外面送进来的要说一声）。
    private func deliver(_ input: [CodexRPC.Object], clientID: String, whenBusy: PiQueueMode?, to session: Tracked) async throws -> PiDelivery {
        let rpc = try await control(session)
        let busy = session.turnRunning
        if busy, whenBusy == .steer, let turn = session.turnID {
            do {
                try await rpc.call("turn/steer", ["threadId": session.threadID, "expectedTurnId": turn, "clientUserMessageId": clientID, "input": input])
                return .queued(.steer)
            } catch CodexRPCError.server(-32600, _) {}
        }
        let queued: CodexRPC.Object
        do {
            queued = try await rpc.call("thread/queue/add", ["threadId": session.threadID, "clientUserMessageId": clientID, "input": input])
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
        guard !busy, let submission = (queued["queuedSubmission"] as? CodexRPC.Object)?["id"] as? String else { return .queued(.followUp) }
        do {
            try await rpc.call("thread/queue/start", ["threadId": session.threadID, "queuedSubmissionId": submission])
        } catch CodexRPCError.server(-32600, _) {
            // 队列自己已经把它取走开始了（"not found"），或刚好有一轮开始（"active or pending turn"）：这一条随它走
        }
        return .immediate
    }

    fileprivate func command(_ line: String, whenBusy: PiQueueMode?, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        let name = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "compact":
            try await call(session, "thread/compact/start", ["threadId": session.threadID])
        case "name":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: nil, thinking: nil, name: argument, in: id)
        case "model":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            let provider = bridge.session(id: id)?.model?.key.provider ?? "openai"
            try await configure(model: PiModelKey(provider: provider, id: argument), thinking: nil, name: nil, in: id)
        case _ where name.hasPrefix("skill:"):
            guard let skill = session.skills.first(where: { "skill:\($0.name)" == name }) else { throw PiBridgeError.rejected("unknown_command") }
            var input: [CodexRPC.Object] = [["type": "skill", "name": skill.name, "path": skill.path]]
            if !argument.isEmpty { input.append(["type": "text", "text": argument, "text_elements": []]) }
            _ = try await deliver(input, clientID: CodexHistory.clientID(for: nil), whenBusy: whenBusy, to: session)
        default:
            throw PiBridgeError.rejected("unknown_command")
        }
    }

    fileprivate func abort(_ id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard session.turnRunning else { return }
        // 在跑的一轮总带着 id（钩子与接上时读到的都有）；没有就是状态坏了，不能当作停下了
        guard let turn = session.turnID else { throw PiBridgeError.rejected("failed: 不知道正在跑的是哪一轮") }
        try await call(session, "turn/interrupt", ["threadId": session.threadID, "turnId": turn])
    }

    /// 改名走 `thread/name/set`；模型与强度走 `thread/settings/update`，强度按新模型支持的范围夹取（取不超过它的最高一档，没有就取最低一档）。
    fileprivate func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard model != nil || thinking != nil || name != nil else { throw PiBridgeError.rejected("bad_request") }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw PiBridgeError.rejected("bad_request") }
            try await call(session, "thread/name/set", ["threadId": session.threadID, "name": trimmed])
            change(id) { $0.name = trimmed }
        }
        if model != nil || thinking != nil {
            let rpc = try await control(session)
            if models == nil { models = try await CodexModel.list(rpc) }
            let target = model?.id ?? bridge.session(id: id)?.model?.key.id
            let entry = models?.first { $0.id == target }
            if model != nil, entry == nil { throw PiBridgeError.rejected("unknown_model") }
            var settings: CodexRPC.Object = ["threadId": session.threadID]
            if let model { settings["model"] = model.id }
            if let thinking { settings["effort"] = CodexModel.effort(entry.map { $0.clamp(thinking) } ?? thinking) }
            try await call(session, "thread/settings/update", settings)
            let read = try await rpc.call("thread/read", ["threadId": session.threadID])
            if let thread = read["thread"] as? CodexRPC.Object { change(id) { self.apply(thread, to: &$0) } }
        }
    }

    fileprivate func endLink(_ id: PiSession.ID) throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard let rpc = hosted[session.pid] else { throw PiBridgeError.unsupported }
        rpc.close()
    }

    private func call(_ session: Tracked, _ method: String, _ params: CodexRPC.Object) async throws {
        do {
            try await control(session).call(method, params)
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
    }
}

/// 一个 Codex 会话的控制通道：转给接入层。重新载入 Codex 没有对应的东西。
@MainActor
private final class CodexLink: SessionLink {
    weak var runtime: CodexRuntime?
    let id: PiSession.ID

    init(runtime: CodexRuntime, id: PiSession.ID) {
        self.runtime = runtime
        self.id = id
    }

    private func live() throws -> CodexRuntime {
        guard let runtime else { throw PiBridgeError.sessionEnded }
        return runtime
    }

    func send(_ message: PiMessage) async throws -> PiDelivery { try await live().send(message, in: id) }
    func command(_ line: String, whenBusy: PiQueueMode?) async throws { try await live().command(line, whenBusy: whenBusy, in: id) }
    func end() async throws { try live().endLink(id) }
    func abort() async throws { try await live().abort(id) }
    func answer(_ answer: PiAnswerValue, to promptID: String) async throws { try live().answer(answer, to: promptID, in: id) }
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        try await live().configure(model: model, thinking: thinking, name: name, in: id)
    }
}

/// `model/list` 里的一个模型：强度是 Codex 的 `ReasoningEffort`（`none` 即关闭；`ultra` 等 CuePad 没有的档丢掉）。
private struct CodexModel {
    let id: String
    let name: String
    let efforts: [PiThinkingLevel]

    func option(provider: String) -> PiModelOption {
        PiModelOption(key: PiModelKey(provider: provider, id: id), name: name, thinkingLevels: efforts)
    }

    func clamp(_ level: PiThinkingLevel) -> PiThinkingLevel {
        let order = PiThinkingLevel.allCases
        let wanted = order.firstIndex(of: level)!
        return efforts.last { order.firstIndex(of: $0)! <= wanted } ?? efforts.first ?? level
    }

    static func thinking(_ effort: String) -> Open<PiThinkingLevel> { Open(rawValue: effort == "none" ? "off" : effort) }
    static func effort(_ level: PiThinkingLevel) -> String { level == .off ? "none" : level.rawValue }

    @MainActor static func list(_ rpc: CodexRPC) async throws -> [CodexModel] {
        let listed = try await rpc.call("model/list", [:])
        return (listed["data"] as? [CodexRPC.Object] ?? []).compactMap { entry in
            guard entry["hidden"] as? Bool != true, let id = entry["id"] as? String else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [CodexRPC.Object] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return CodexModel(id: id, name: entry["displayName"] as? String ?? id, efforts: efforts.compactMap { thinking($0).known })
        }
    }
}
#endif

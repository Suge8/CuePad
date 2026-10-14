#if os(macOS)
import CueStore
import Foundation
import OSLog

/// Codex 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它常驻服务的控制 socket 说话；后台托管的会话是 CuePad 起的 `codex app-server`。
///
/// - 状态来自钩子：提交一句话进入工作，调工具、等权限确认、压缩、子代理随事件更新，`Stop`/`Interrupt` 歇下，`SessionEnd` 下线。
///   托管的会话另有自己进程的 `turn/started`、`turn/completed` 通知管忙闲（钩子没装好时也对）。
///   会话 id 是 `<线程 id>.<承载进程>`：终端会话的承载进程是钩子的父进程（常驻服务）；托管的是 CuePad 起的进程，它的钩子按环境里的
///   `HostMark` 认回（`codex` 可能是外壳，钩子的父进程是外壳起的子进程，不按进程号认）。
///   承载进程退出时它上面的会话都下线。常驻服务里的线程在终端退出后还会挂着（没有订阅者、闲置后才卸载并报 `SessionEnd`），
///   这段时间它仍在线、能收话，这是 Codex 的语义。
/// - 控制只经 app-server 的接口，不为观察而订阅（`thread/resume` 会把终端的事件与审批抢走）：说话是 `turn/steer`（马上说，
///   插进在跑的这一轮）与 `thread/queue/add`（等它做完再说，空闲时立刻开始），停止是 `turn/interrupt`，换模型与强度是
///   `thread/settings/update`，改名是 `thread/name/set`，斜杠命令只有映射得上的几个。常驻服务把 `thread/status/changed`、
///   `thread/name/updated`、`thread/closed` 广播给所有连接：钩子漏掉的歇下（出错时没有 `Stop`）与改名靠它们补上。
///   常驻服务的控制 socket 在哪由 `codex app-server daemon version` 告诉（服务在跑时才有），不自己拼路径。
/// - 权限确认经 `PermissionRequest` 钩子：Codex 先问钩子、钩子没给决定才在终端里弹框。终端会话按人在不在分（`PresenceGate`）；
///   托管的会话没有终端，总是挂住。在终端里按 Esc 停下这一轮会收回挂住的调用。
/// - Plan 模式的提问（`request_user_input`）只发给开出线程的连接：终端会话的只能在终端里答（CuePad 只显示）；托管会话的经
///   `item/tool/requestUserInput` 发给 CuePad，只有一个问题时能从 CuePad 答。
@MainActor
public final class CodexRuntime: AgentRuntime {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "codex")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
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
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    private var models: [CodexModel]?
    private var stopped = true

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, presence: any UserPresence = SystemPresence()
    ) {
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locate = locate
        gate = PresenceGate(presence: presence)
    }

    /// 一个在线会话在这里的状态（快照在桥上，由 `facts` 推出）。
    private final class Tracked {
        let id: PiSession.ID
        let threadID: String
        let pid: Int32
        var facts = SessionFacts()
        /// 这一轮的 id（`turn/steer`、`turn/interrupt` 要它）
        var turnID: String?
        /// 要你回答的那一个怎么回给 Codex（与 `facts.questions` 一一对应，只有一个）
        var reply: Reply?
        /// 发起的子代理的任务名，等 `SubagentStart` 认领（按先后）
        var spawnNames: [String] = []
        /// 这一轮报过的错误原文（`error` 通知），出错歇下时用
        var lastError: String?
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
        Task { await discover() }
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
        let locator = await locate()
        guard let codex = locator.executable(.codex) else { throw AgentRuntimeError.notInstalled(.codex) }
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

    /// 启动时把常驻服务里已经载入的线程接上（CuePad 晚于终端里的会话启动）。子代理的线程不算会话。
    private func discover() async {
        do {
            guard let rpc = try await daemonConnection() else { return }
            let loaded = try await rpc.call("thread/loaded/list", [:])
            for threadID in loaded["data"]?.array?.compactMap(\.string) ?? [] where tracked["\(threadID).\(rpc.pid)"] == nil {
                _ = try await adopt(threadID, on: rpc)
            }
        } catch {
            Self.log.notice("没能读出常驻服务里的会话：\(String(describing: error))")
        }
    }

    private func adoptFromDaemon(_ threadID: String) async throws -> PiSession.ID? {
        guard let rpc = try? await daemonConnection() else { return nil }
        let loaded = try await rpc.call("thread/loaded/list", [:])
        guard loaded["data"]?.array?.contains(.string(threadID)) == true else { return nil }
        return try await adopt(threadID, on: rpc)
    }

    @discardableResult
    private func adopt(_ threadID: String, on rpc: CodexRPC) async throws -> PiSession.ID? {
        let id = "\(threadID).\(rpc.pid)"
        if tracked[id] != nil { return id }
        let read = try await rpc.call("thread/read", ["threadId": .string(threadID)])
        guard let thread = read["thread"], thread["parentThreadId"] == nil || thread["parentThreadId"] == .null else { return nil }
        // 正在跑一轮：停止、插话要这一轮的 id，从最近一轮取（钩子要等下一个事件才带来）
        var running: String?
        if thread["status"]?["type"]?.string == "active" {
            let turns = try await rpc.call("thread/turns/list", ["threadId": .string(threadID), "limit": 1])
            running = turns["data"]?.array?.first.flatMap { $0["status"]?.string == "inProgress" ? $0["id"]?.string : nil }
        }
        if tracked[id] != nil { return id }
        attach(makeSession(thread, pid: rpc.pid)) { session in
            session.turnID = running
            if running != nil { session.facts.startTurn() }
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
        bridge.attach(session, via: CodexLink(runtime: self, id: session.id))
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
        for session in tracked.values where session.pid == pid { detach(session.id) }
    }

    private func detach(_ id: PiSession.ID) {
        guard let session = tracked.removeValue(forKey: id) else { return }
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
                    let commands = Self.builtinCommands + entries.compactMap { entry -> PiSlashCommand? in
                        guard let name = entry["name"]?.string else { return nil }
                        return PiSlashCommand(name: "skill:\(name)", summary: entry["description"]?.string.map { ToolDetail.clip($0) }, source: .known(.skill))
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

    /// 会话的控制通道：托管的是它的进程，终端里的是常驻服务（钩子的父进程就是它才算；`codex exec` 之类没有控制接口）。
    private func control(_ session: Tracked) async throws -> CodexRPC {
        if let rpc = hosted[session.pid] { return rpc }
        guard let rpc = try await daemonConnection(), rpc.pid == session.pid else { throw PiBridgeError.unsupported }
        return rpc
    }

    /// 把事实写进桥上的会话。
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
        let session = tracked[id] ?? adoptFromHook(threadID, pid: pid, input)
        let agent = input["agent_id"]?.string
        if let turn = input["turn_id"]?.string, agent == nil { session.turnID = turn }
        let tool = input["tool_name"]?.string ?? ""
        let now = Date.now
        switch event {
        case "PermissionRequest":
            // 子代理要的确认也挂在这个会话上问
            return ask(session, call: call, input)
        case "SubagentStart":
            if let agent {
                let role = input["agent_type"]?.string ?? "default"
                session.facts.startSubagent(agent, name: session.spawnNames.isEmpty ? role : session.spawnNames.removeFirst(), role: role, at: now)
            }
        case "SubagentStop":
            if let agent { session.facts.settleSubagent(agent, .done, summary: input["last_assistant_message"]?.string, at: now) }
        case _ where agent != nil:
            // 子代理自己线程里的事件（session_id 是同一棵树的根，agent_id 是它自己）：只更新它在做什么
            if event == "PreToolUse", let agent { session.facts.updateSubagent(agent) { $0.action = ToolDetail.line(tool, input["tool_input"]) } }
        case "UserPromptSubmit":
            session.facts.startTurn()
            bridge.update(id) { s in
                if s.firstMessage == nil, let prompt = input["prompt"]?.string, !prompt.isEmpty {
                    s.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
                }
            }
            refresh(id)
        case "PreToolUse":
            if tool.hasSuffix("spawn_agent"), let name = input["tool_input"]?["task_name"]?.string { session.spawnNames.append(name) }
            if tool == "request_user_input", session.reply == nil {
                // 终端会话的 Plan 模式提问只发给终端界面：CuePad 只显示（托管的经 `item/tool/requestUserInput` 来）
                session.facts.questions = [Self.userInput(input["tool_input"] ?? .object([:]), promptID: nil)]
            } else {
                session.facts.work(.tool, detail: ToolDetail.line(tool, input["tool_input"]))
            }
        case "PostToolUse":
            if session.reply == nil { session.facts.questions = [] }
            session.facts.work(.thinking)
        case "PreCompact":
            session.facts.compacting = true
        case "PostCompact":
            session.facts.compacting = false
        case "Stop", "Interrupt":
            release(session)
            session.facts.endTurn()
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
    private func adoptFromHook(_ threadID: String, pid: Int32, _ input: JSONValue) -> Tracked {
        let session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: input["transcript_path"]?.string.map { URL(filePath: $0) },
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
        let action = arguments["command"]?.string.map { "Codex 想运行：\($0)" } ?? "Codex 想用 \(input["tool_name"]?.string ?? "工具")"
        let text = String([action, arguments["description"]?.string].compactMap { $0 }.joined(separator: "\n").prefix(500))
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

    /// Plan 模式的提问（`request_user_input` 的参数，一次可能几个，显示第一个）：有选项是单选，否则填文字；标题与问题换行连接。
    private static func userInput(_ arguments: JSONValue, promptID: String?) -> PiQuestion {
        let first = arguments["questions"]?.array?.first ?? .object([:])
        let text = [first["header"]?.string, first["question"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let options = (first["options"]?.array ?? []).compactMap { $0["label"]?.string }
        return PiQuestion(promptID: promptID, kind: options.isEmpty ? .text : .select, text: String(text.prefix(500)), options: options)
    }

    /// 作答：权限确认写回钩子（允许或拒绝，附一句给模型看的原因），托管线程的提问回给服务端请求。
    fileprivate func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) throws {
        guard let session = tracked[id], let reply = session.reply, let question = session.facts.questions.first else {
            throw PiBridgeError.rejected("no_prompt")
        }
        guard question.promptID == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        switch (reply, answer) {
        case (.hook(let call, let hold), .confirmed(let allowed)):
            let decision: JSONValue = ["behavior": allowed ? "allow" : "deny", "message": allowed ? "在 CuePad 里允许了" : "在 CuePad 里拒绝了"]
            call.reply(JSONValue.object(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]).data)
            gate.drop(hold)
        case (.request(let rpc, let requestID, let questionID), .option(let text)) where question.options.contains(text),
             (.request(let rpc, let requestID, let questionID), .text(let text)) where question.options.isEmpty:
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
        guard let threadID = params["threadId"]?.string, let session = tracked["\(threadID).\(pid)"] else { return }
        switch method {
        case "thread/name/updated":
            bridge.update(session.id) { $0.name = params["threadName"]?.string }
            return
        case "thread/status/changed":
            switch params["status"]?["type"]?.string {
            // 钩子漏报的歇下（出错的一轮没有 Stop）；钩子的 Stop 晚到也只是再歇一次
            case "idle" where session.facts.running:
                release(session)
                session.facts.endTurn()
            case "systemError":
                release(session)
                session.facts.endTurn(failure: session.lastError ?? "Codex 出错了")
                if session.lastError == nil { readFailure(session) }
            default: return
            }
        case "error" where params["willRetry"]?.bool != true:
            // 出错的原文（常驻服务也广播）；随后的 systemError 或失败的 turn/completed 用它
            session.lastError = CodexModel.failure(of: params)
            return
        // 以下只有开出这个线程的连接（托管的进程）收得到
        case "turn/started":
            session.turnID = params["turn"]?["id"]?.string
            session.lastError = nil
            guard !session.facts.running else { return }
            session.facts.startTurn()
        case "turn/completed" where params["turn"]?["status"]?.string == "failed":
            // 失败的一轮没有 Stop 钩子，状态停在这里
            release(session)
            session.facts.endTurn(failure: session.lastError ?? CodexModel.failure(of: params["turn"]))
        case "turn/completed":
            guard session.facts.running else { return }
            release(session)
            session.facts.endTurn()
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
                  let turns = try? await rpc.call("thread/turns/list", ["threadId": .string(session.threadID), "limit": 1]),
                  let turn = turns["data"]?.array?.first, turn["status"]?.string == "failed", tracked[session.id] === session,
                  !session.facts.running else { return }
            session.facts.failure = CodexModel.failure(of: turn)
            publish(session)
        }
    }

    // MARK: 命令（`CodexLink` 转来）

    fileprivate func send(_ message: PiMessage, in id: PiSession.ID) async throws -> PiDelivery {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        var input: [JSONValue] = message.text.isEmpty ? [] : [["type": "text", "text": .string(message.text), "text_elements": []]]
        input += message.images.map { ["type": "image", "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")] }
        return try await deliver(input, clientID: CodexHistory.clientID(for: message.deliveryID), whenBusy: message.whenBusy, to: session)
    }

    /// 马上说：插进在跑的这一轮；刚好歇下（没有这一轮了）就排进队列。等它做完再说、空闲时都进队列，空闲时再让队列里的这一条开始：
    /// 停下一轮之后 Codex 不自动接着跑队列（终端里的界面会自己开始，外面送进来的要说一声）。
    private func deliver(_ input: [JSONValue], clientID: String, whenBusy: PiQueueMode?, to session: Tracked) async throws -> PiDelivery {
        let rpc = try await control(session)
        let busy = session.facts.running
        let thread = JSONValue.string(session.threadID), items = JSONValue.array(input), client = JSONValue.string(clientID)
        if busy, whenBusy == .steer, let turn = session.turnID {
            do {
                try await rpc.call("turn/steer", ["threadId": thread, "expectedTurnId": .string(turn), "clientUserMessageId": client, "input": items])
                return .queued(.steer)
            } catch CodexRPCError.server(-32600, _) {}
        }
        let queued: JSONValue
        do {
            queued = try await rpc.call("thread/queue/add", ["threadId": thread, "clientUserMessageId": client, "input": items])
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
        guard !busy, let submission = queued["queuedSubmission"]?["id"] else { return .queued(.followUp) }
        do {
            try await rpc.call("thread/queue/start", ["threadId": thread, "queuedSubmissionId": submission])
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
            try await call(session, "thread/compact/start", ["threadId": .string(session.threadID)])
        case "name":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: nil, thinking: nil, name: argument, in: id)
        case "model":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: PiModelKey(provider: CodexModel.provider, id: argument), thinking: nil, name: nil, in: id)
        case _ where name.hasPrefix("skill:"):
            guard let skill = session.skills.first(where: { "skill:\($0.name)" == name }) else { throw PiBridgeError.rejected("unknown_command") }
            var input: [JSONValue] = [["type": "skill", "name": .string(skill.name), "path": .string(skill.path)]]
            if !argument.isEmpty { input.append(["type": "text", "text": .string(argument), "text_elements": []]) }
            _ = try await deliver(input, clientID: CodexHistory.clientID(for: nil), whenBusy: whenBusy, to: session)
        default:
            throw PiBridgeError.rejected("unknown_command")
        }
    }

    fileprivate func abort(_ id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard session.facts.running else { return }
        // 在跑的一轮总带着 id（钩子与接上时读到的都有）；没有就是状态坏了，不能当作停下了
        guard let turn = session.turnID else { throw PiBridgeError.rejected("failed: 不知道正在跑的是哪一轮") }
        try await call(session, "turn/interrupt", ["threadId": .string(session.threadID), "turnId": .string(turn)])
    }

    /// 改名走 `thread/name/set`；模型与强度走 `thread/settings/update`，强度按新模型支持的范围夹取（`PiThinkingLevel.clamped`）。
    fileprivate func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
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
        if model != nil, entry == nil { throw PiBridgeError.rejected("unknown_model") }
        var settings: [String: JSONValue] = ["threadId": .string(session.threadID)]
        if let model { settings["model"] = .string(model.id) }
        if let thinking { settings["effort"] = .string(CodexModel.effort(thinking.clamped(to: entry?.efforts ?? []))) }
        try await call(session, "thread/settings/update", .object(settings))
        if let thread = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])["thread"] {
            bridge.update(id) { self.apply(thread, to: &$0) }
        }
    }

    /// 托管的会话关掉进程（app-server 读到 EOF 收尾退出）；终端里的会话 Codex 没有让终端退出的接口（能力表里没有，桥先拒绝）。
    fileprivate func end(_ id: PiSession.ID) throws {
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

/// 一个 Codex 会话的控制通道：转给接入。
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
    func end() async throws { try live().end(id) }
    func abort() async throws { try await live().abort(id) }
    func answer(_ answer: PiAnswerValue, to promptID: String) async throws { try live().answer(answer, to: promptID, in: id) }
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        try await live().configure(model: model, thinking: thinking, name: name, in: id)
    }
}

/// `model/list` 里的一个模型：强度是 Codex 的 `ReasoningEffort`（`none` 即关闭；`ultra` 等 CuePad 没有的档丢掉）。
struct CodexModel {
    let id: String
    let name: String
    let efforts: [PiThinkingLevel]

    /// 模型的提供方写成 Codex 自己（`AgentKind.modelProvider`），不用线程上的 `modelProvider`（openai 等）：Codex 的模型 id 在它自己的命名空间里。
    static let provider = AgentKind.codex.modelProvider!

    var option: PiModelOption {
        PiModelOption(key: PiModelKey(provider: Self.provider, id: id), name: name, thinkingLevels: efforts)
    }

    static func thinking(_ effort: String) -> Open<PiThinkingLevel> { Open(rawValue: effort == "none" ? "off" : effort) }
    static func effort(_ level: PiThinkingLevel) -> String { level == .off ? "none" : level.rawValue }

    /// 失败的一轮（`turn/completed` 的 `status` 为 failed）的原因：`turn.error` 的说明，带上补充细节。
    static func failure(of turn: JSONValue?) -> String {
        let message = [turn?["error"]?["message"]?.string, turn?["error"]?["additionalDetails"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
        return message.isEmpty ? "Codex 这一轮失败了" : message.joined(separator: "\n")
    }

    @MainActor static func list(_ rpc: CodexRPC) async throws -> [CodexModel] {
        let listed = try await rpc.call("model/list", [:])
        return (listed["data"]?.array ?? []).compactMap { entry in
            guard entry["hidden"]?.bool != true, let id = entry["id"]?.string else { return nil }
            let efforts = (entry["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
            return CodexModel(id: id, name: entry["displayName"]?.string ?? id, efforts: efforts.compactMap { thinking($0).known })
        }
    }
}
#endif

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
    static let log = Logger(subsystem: AppIdentity.id, category: "codex")
    let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    /// 这家的可执行文件（检测时挑中的那个，`AgentStatus.executable`）；没有为 nil
    let codex: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    let gate: PresenceGate
    var tracked: [PiSession.ID: Tracked] = [:]
    var hosted: [Int32: CodexRPC] = [:]
    /// 托管进程环境里的标记（`HostMark`）→ 进程号
    var marks: [String: Int32] = [:]
    var daemon: CodexRPC?
    var connecting: Task<CodexRPC, any Error>?
    /// 常驻服务的控制 socket（服务在跑时问到的）
    var controlSocket: String?
    var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    /// 收到过推送的线程（`<线程 id>.<承载进程>`）属于谁：会话的子代理（名字、角色）、不是子代理（Codex 自己起的临时线程等），
    /// 或还在问 Codex（先攒着它的推送）
    var threads: [String: Owner] = [:]
    enum Owner {
        case asking([(method: String, params: JSONValue)])
        case session(PiSession.ID, name: String, role: String)
        case foreign
    }
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    var models: [CodexModel]?
    var stopped = true
    /// 终端会话哪些接上桥（`follow`）；给之前一个都不接
    var scope = PiHistoryScope.sessions([])

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

    /// 以一句话开新一轮的进展：正在停下这一轮，或这一轮已经结束（被停下或恰好自己做完）、等这句开出新的一轮。
    enum Restart { case stopping, stopped }

    /// 一个在线会话在这里的状态（快照在桥上，由 `facts` 推出）。
    final class Tracked {
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
            let started = try await rpc.call("thread/start", .object(try await self.sandbox(in: directory.path, on: rpc).merging(["cwd": .string(directory.path)]) { $1 }))
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
                let params: [String: JSONValue] = ["threadId": .string(session.id), "path": .string(session.path), "excludeTurns": true]
                let resumed = try await rpc.call("thread/resume", .object(try await self.sandbox(in: session.cwd, on: rpc).merging(params) { $1 }))
                return self.attachHosted(resumed, rpc: rpc, launchToken: nil)
            }
        } catch CodexRPCError.server(_, let message) where message.contains("active writer") {
            if let id = try await adoptFromDaemon(session.id) { return id }
            throw AgentRuntimeError.openElsewhere
        }
    }

    // MARK: 托管进程

    /// 托管会话的沙箱：用户、项目或管理配置定过（`sandbox_mode`，或权限档 `default_permissions`，含比工作区更宽的）就照它，不传；
    /// 都没定时 Codex 对没被信任过的目录用只读——终端里第一次进目录会问信不信任，托管的会话没人回答，写工作区的每一步都要申请。
    /// CuePad 开的会话就是叫它在这个目录里干活：这时给工作区写权限（同信任过的目录的缺省）。`thread/resume` 不留开线程时的沙箱，接着时也要给。
    private func sandbox(in directory: String, on rpc: CodexRPC) async throws -> [String: JSONValue] {
        let origins = try await rpc.call("config/read", ["cwd": .string(directory)])["origins"]?.object ?? [:]
        return origins.keys.contains("sandbox_mode") || origins.keys.contains("default_permissions") ? [:] : ["sandbox": "workspace-write"]
    }

    /// `codex` 与给它的环境：配置目录与钩子 socket 目录照 `AgentPaths` 定（隔离测试里指到临时目录）。
    func executable() async throws -> (url: URL, environment: [String: String]) {
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
}
#endif

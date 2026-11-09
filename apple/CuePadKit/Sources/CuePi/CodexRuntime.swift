#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

/// 托管的会话一轮的起止、成败、正在说的话只看它的驱动（`CodexDriver`，与 Cue 的大脑同一个），钩子只管这一轮里在做什么与权限确认。
/// 子线程没有订阅者，它的推送广播给所有连接（实测、文档没写），所以子代理只认 app-server 的子线程推送。钩子不行：`SubagentStop` 只在正常做完时发，出错、被停没有；v2 `followup_task` 再跑不发 `SubagentStart`。
/// 父线程歇着时子代理做完，Codex 不自己接着跑（结果在它的历史或邮箱里等下一轮）：最后一个落定时 CuePad 补一轮空输入（`wake`）。
/// 常驻服务里的线程在终端退出后还会挂着（没有订阅者、闲置约 30 分钟后才卸载并报 `SessionEnd`，实测、文档没写），这段时间它仍在线、能收话。
/// 正在说的话（`PiDraft`）与上下文余量只有托管的会话有：增量与用量只发给订阅了线程的连接（自己起的进程）；终端里的会话不订阅，也就没有。
/// 控制只经 app-server 的接口，不为观察而订阅（`thread/resume` 会把终端的事件与审批抢走）：说话在跑就先 `turn/interrupt`（`turn/steer` 要等在跑的工具做完才读到，不是打断）。
/// 常驻服务把 `thread/status/changed`、`thread/name/updated`、`thread/closed` 广播给所有连接：钩子漏掉的歇下（出错时没有 `Stop`）与改名靠它们补上。
/// 常驻服务的控制 socket 在哪由 `codex app-server daemon version` 告诉（服务在跑时才有），不自己拼路径。
/// 权限确认：Codex 先问钩子、钩子没给决定才在终端里弹框；在终端里按 Esc 停下这一轮会收回挂住的调用。
/// Plan 模式提问有两种：
/// - 不挡着这一轮的（`request_user_input_async`，0.162 起 Plan 模式的默认）：Codex 登记了问题就接着做事、睡着等或歇下，你的下一句话就是答案。
///   终端与托管的会话都经 `PostToolUse` 钩子（工具被接受了才有）显示成等你回答，从 CuePad 作答就是对它说这句话（`deliver`），
///   你说了下一句（`UserPromptSubmit`）就收起。
/// - 挡着这一轮的（`request_user_input`）只发给开出线程的连接：终端会话的只能在终端里答（CuePad 只显示）；
///   托管会话的经 `item/tool/requestUserInput` 发给 CuePad，只有一个问题时能从 CuePad 答。
@MainActor
public final class CodexRuntime: AgentRuntime, SessionLink {
    static let log = Logger(subsystem: AppIdentity.id, category: "codex")
    let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    let codex: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    let gate: PresenceGate
    var tracked: [PiSession.ID: Tracked] = [:]
    var hosted: [Int32: CodexDriver] = [:]
    var marks: [String: Int32] = [:]
    var daemon: CodexRPC?
    var connecting: Task<CodexRPC?, any Error>?
    var scanning: Scan?
    final class Scan {
        var task: Task<Void, Never>?
        var again = false
    }
    var controlSocket: String?
    var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    var threads: [String: Owner] = [:]
    enum Owner {
        case asking([(method: String, params: JSONValue)])
        case session(PiSession.ID, name: String, role: String)
        case foreign
    }
    var naming: [String: CodexNamingTurn] = [:]
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    var models: [CodexModel]?
    var stopped = true
    let timing: Timing
    var scope = PiHistoryScope.sessions([])

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, codex: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, presence: any UserPresence = SystemPresence(),
        timing: Timing = .system
    ) {
        self.timing = timing
        self.codex = codex
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locate = locate
        gate = PresenceGate(presence: presence)
    }

    enum Restart { case stopping, stopped }

    final class Tracked {
        let id: PiSession.ID
        let threadID: String
        let pid: Int32
        var facts = SessionFacts()
        /// 要你回答的那一个怎么回给 Codex（与 `facts.questions` 一一对应，只有一个）
        var reply: Reply?
        /// 父线程歇着时落定、结果还没交给一轮的子代理（线程 id）：有没有交回结果（做完、出错交回；被停下的不交）
        var unread: [String: Bool] = [:]
        var lastWords: [String: String] = [:]
        /// 这一轮报过的错误原文（终端会话是常驻服务广播的 `error` 通知，托管的是驱动报的 `failed`），出错歇下时用
        var lastError: String?
        /// CuePad 正以一句话开新一轮（`deliver`）：期间一轮结束不算歇下，接着就是这句开的那一轮
        var restarting: Restart?
        var restartGeneration = 0
        let stopPhase = StopPhase()
        var skills: [(name: String, path: String)] = []

        init(id: PiSession.ID, threadID: String, pid: Int32) {
            self.id = id
            self.threadID = threadID
            self.pid = pid
        }

        enum Reply {
            case hook(AgentHookCall, hold: UUID?)
            case request(CodexRPC, id: JSONValue, question: String)
        }
    }

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
        let (connecting, scan) = (connecting, scanning?.task)
        connecting?.cancel()
        scan?.cancel()
        self.connecting = nil
        scanning = nil
        let waits = hosted.values.compactMap(\.rpc).map { rpc in Task { await rpc.shutdown() } }
        return {
            _ = try? await connecting?.value
            await scan?.value
            for wait in waits { await wait.value }
        }
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let id = try await launch { driver, rpc in
            let started = try await driver.open("thread/start", .object(try await self.sandbox(in: directory.path, on: rpc).merging(["cwd": .string(directory.path)]) { $1 }))
            return self.attachHosted(started, rpc: rpc, launchToken: launchToken)
        }
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 恢复时它被别处拿着写（终端里刚开）也改走控制 socket；常驻服务里也没有它才报错。
    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: session.id) { return live.id }
        if let id = try await adoptFromDaemon(session.id) { return id }
        do {
            return try await launch { driver, rpc in
                let params: [String: JSONValue] = ["threadId": .string(session.id), "path": .string(session.path), "excludeTurns": true]
                let resumed = try await driver.open("thread/resume", .object(try await self.sandbox(in: session.cwd, on: rpc).merging(params) { $1 }))
                return self.attachHosted(resumed, rpc: rpc, launchToken: nil)
            }
        } catch CodexRPCError.server(_, let message) where message.contains("active writer") {
            if let id = try await adoptFromDaemon(session.id) { return id }
            throw AgentRuntimeError.openElsewhere
        }
    }

    /// 托管会话的沙箱：用户、项目或管理配置定过（`sandbox_mode`，或权限档 `default_permissions`，含比工作区更宽的）就照它，不传；
    /// 都没定时 Codex 对没被信任过的目录用只读——终端里第一次进目录会问信不信任，托管的会话没人回答，写工作区的每一步都要申请。
    /// CuePad 开的会话就是叫它在这个目录里干活：这时给工作区写权限（同信任过的目录的缺省）。`thread/resume` 不留开线程时的沙箱，接着时也要给。
    private func sandbox(in directory: String, on rpc: CodexRPC) async throws -> [String: JSONValue] {
        let origins = try await rpc.call("config/read", ["cwd": .string(directory)])["origins"]?.object ?? [:]
        return origins.keys.contains("sandbox_mode") || origins.keys.contains("default_permissions") ? [:] : ["sandbox": "workspace-write"]
    }

    func executable() async throws -> (url: URL, environment: [String: String]) {
        guard let codex = await codex() else { throw AgentRuntimeError.notInstalled(.codex) }
        let locator = await locate()
        return (codex, locator.environment(launching: codex, overrides: paths.launchEnvironment(of: .codex).merging(
            ["CUEPAD_PI_SOCKET_DIR": paths.pi.socketDirectory.path]) { $1 }))
    }

    /// 连同握手至多 `AgentTimeouts.launch`，超时或出错时停掉进程。
    private func launch(_ body: @escaping @MainActor (CodexDriver, CodexRPC) async throws -> PiSession.ID) async throws -> PiSession.ID {
        let codex = try await executable()
        let mark = UUID().uuidString
        let driver = CodexDriver()
        let rpc = try await driver.launch(codex.url, environment: codex.environment.merging([HostMark.variable: mark]) { $1 })
        host(driver, rpc, mark: mark)
        do {
            return try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: AgentRuntimeError.launchTimedOut(.codex)) { try await body(driver, rpc) }
        } catch {
            await rpc.shutdown()
            throw error as? CodexRPCError == .timedOut ? AgentRuntimeError.launchTimedOut(.codex) : error
        }
    }

    private func host(_ driver: CodexDriver, _ rpc: CodexRPC, mark: String) {
        let pid = rpc.pid
        hosted[pid] = driver
        marks[mark] = pid
        driver.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        driver.onEvent = { [weak self] event in self?.event(event, from: pid) }
        rpc.onRequest = { [weak self, weak rpc] method, id, params in
            guard let self, let rpc, method == "item/tool/requestUserInput" else { return false }
            return self.userInput(params, id: id, on: rpc)
        }
    }

    private func attachHosted(_ result: JSONValue, rpc: CodexRPC, launchToken: String?) -> PiSession.ID {
        var session = makeSession(result["thread"] ?? .object([:]), pid: rpc.pid)
        session.hosted = true
        session.fast = result["serviceTier"]?.string == "priority"
        session.launchToken = launchToken
        attach(session)
        return session.id
    }
}
#endif

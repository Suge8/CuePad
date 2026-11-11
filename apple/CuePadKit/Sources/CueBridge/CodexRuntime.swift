#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

/// CuePad 只管自己起的 Codex（每个会话一个 app-server 进程，经标准输入输出）：一轮的起止、成败、在做什么、正在说的话与上下文余量都来自它的驱动（`CodexDriver`，与 Cue 的大脑同一个），
/// 权限确认与提问是它发来的服务端请求，子代理、压缩、不挡着这一轮的提问看线程的推送。不往 Codex 的配置里写任何东西。
/// 子线程没有订阅者，它的推送广播给所有连接（实测、文档没写），所以子代理只认 app-server 的子线程推送。
/// 父线程歇着时子代理做完，Codex 不自己接着跑（结果在它的历史或邮箱里等下一轮）：最后一个落定时 CuePad 补一轮空输入（`wake`）。
/// 说话在跑就先 `turn/interrupt`（`turn/steer` 要等在跑的工具做完才读到，不是打断）。
/// Plan 模式提问有两种：
/// - 不挡着这一轮的（`request_user_input_async`，0.162 起 Plan 模式的默认，gpt-6 一档才有）：问题是一条 `delivery` 为 async 的 `agentMessage`，
///   Codex 登记了就接着做事、睡着等或歇下，你的下一句话就是答案：显示成等你回答，从 CuePad 作答就是对它说这句话（`deliver`），你说了下一句就收起。
/// - 挡着这一轮的（`request_user_input`）经 `item/tool/requestUserInput` 发来，只有一个问题时能从 CuePad 答。
@MainActor
public final class CodexRuntime: AgentRuntime, SessionLink {
    static let log = Logger(subsystem: AppIdentity.id, category: "codex")
    let bridge: Bridge
    private let paths: AgentPaths
    let codex: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    var tracked: [Session.ID: Tracked] = [:]
    var hosted: [Int32: CodexDriver] = [:]
    /// 托管会话的进程按会话（线程 id）登记，请退出与接着都经它（`HostedProcesses`）
    let processes: HostedProcesses
    var threads: [String: Owner] = [:]
    enum Owner {
        case asking([(method: String, params: JSONValue)])
        /// 刚起的线程，推送先到、`thread/read` 还读不到它（实测偶发，负载高时更常见），或这次读被取消、没及时回：留着已收下的推送，下一条推送来时再问
        case unreadable([(method: String, params: JSONValue)])
        case session(Session.ID, name: String, role: String)
        /// 沿父线程到顶也不是跟踪着的会话，或报出来的顶层线程：之后的推送不再问
        case foreign

        var pending: [(method: String, params: JSONValue)]? {
            switch self {
            case .asking(let queued), .unreadable(let queued): queued
            case .session, .foreign: nil
            }
        }
    }
    var naming: [String: CodexNamingTurn] = [:]
    /// `model/list` 的结果（账号可用的模型对所有会话一样），第一次要时取
    var models: [CodexModel]?
    var stopped = true
    let timing: Timing

    public init(
        bridge: Bridge, paths: AgentPaths, codex: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, timing: Timing = .system
    ) {
        self.timing = timing
        self.codex = codex
        self.bridge = bridge
        processes = HostedProcesses(bridge: bridge, timing: timing)
        self.paths = paths
        self.locate = locate
    }

    enum Restart { case stopping, stopped }

    final class Tracked {
        let id: Session.ID
        let threadID: String
        let driver: CodexDriver
        let pid: Int32
        var facts = SessionFacts()
        /// 要你回答的那一个怎么回给 Codex（与 `facts.questions` 一一对应，只有一个）
        var reply: Reply?
        /// 父线程歇着时落定、结果还没交给一轮的子代理（线程 id）：有没有交回结果（做完、出错交回；被停下的不交）
        var unread: [String: Bool] = [:]
        var lastWords: [String: String] = [:]
        /// 这一轮驱动报的失败原文（`failed`），出错歇下时用
        var lastError: String?
        /// CuePad 发出 `turn/start` 前的时刻：它开出的一轮从这里算起。收到开始通知的时刻在负载高时可能晚于这一轮在会话文件里的回答（实测）
        var sentAt: Date?
        /// 这一轮已结束、先认清同一进程上认不出主人的线程再歇下（`endTurn`）；期间 `facts` 仍是在跑
        var ending: Task<Void, Never>?
        /// 这一轮派出、还没认出的子代理（任务名，父线程的 `subAgentActivity` 报的）：子线程的推送与父线程的一轮结束不分先后，
        /// 推送晚到时一轮结束还不知道有它（`endTurn` 等它认出，`recognized` 报每次认出）
        var spawned: Set<String> = []
        var recognized: Occurrences?
        /// CuePad 正以一句话开新一轮（`deliver`）：期间一轮结束不算歇下，接着就是这句开的那一轮
        var restarting: Restart?
        var restartGeneration = 0
        let stopPhase = StopPhase()
        var skills: [(name: String, path: String)] = []

        init(id: Session.ID, threadID: String, driver: CodexDriver, pid: Int32) {
            self.id = id
            self.threadID = threadID
            self.driver = driver
            self.pid = pid
        }

        /// 服务端请求（`id` 是它的请求 id）
        enum Reply {
            /// `item/tool/requestUserInput`：答案按问题的 id 回
            case question(CodexRPC, id: JSONValue, question: String)
            /// 权限确认：允许、拒绝各回什么
            case approval(CodexRPC, id: JSONValue, allow: JSONValue, deny: JSONValue)

            var request: JSONValue {
                switch self {
                case .question(_, let id, _), .approval(_, let id, _, _): id
                }
            }
        }
    }

    public func start() throws {
        guard stopped else { return }
        stopped = false
        processes.start()
    }

    public func stop() -> @concurrent @Sendable () async -> Void {
        stopped = true
        for session in tracked.values {
            session.reply = nil
            session.ending?.cancel()
        }
        let waits = hosted.values.compactMap(\.rpc).map { rpc in Task { await rpc.shutdown() } }
        let launching = processes.stop()
        return {
            await launching()
            for wait in waits { await wait.value }
        }
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID {
        let id = try await launch(sessionID: nil, admission: try processes.admission()) { driver, rpc in
            let started = try await driver.open("thread/start", .object(try await self.sandbox(in: directory.path, on: rpc).merging(["cwd": .string(directory.path)]) { $1 }))
            return self.attachHosted(started, driver: driver, rpc: rpc, launchToken: launchToken)
        }
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 它正被别处拿着写（终端或桌面版里开着）时报 `openElsewhere`。
    public func resume(_ session: IndexedSession) async throws -> Session.ID {
        if let live = bridge.session(sessionID: session.id) { return live.id }
        return try await processes.resume(session.id) { [self] admission in
            do {
                return try await launch(sessionID: session.id, admission: admission) { driver, rpc in
                    let params: [String: JSONValue] = ["threadId": .string(session.id), "path": .string(session.path), "excludeTurns": true]
                    let resumed = try await driver.open("thread/resume", .object(try await self.sandbox(in: session.cwd, on: rpc).merging(params) { $1 }))
                    return self.attachHosted(resumed, driver: driver, rpc: rpc, launchToken: nil)
                }
            } catch CodexRPCError.server(_, let message) where message.contains("active writer") {
                throw AgentRuntimeError.openElsewhere
            }
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
    private func launch(
        sessionID: String?, admission: HostedProcesses.Admission, _ body: @escaping @MainActor (CodexDriver, CodexRPC) async throws -> Session.ID
    ) async throws -> Session.ID {
        let codex = try await executable()
        let driver = CodexDriver()
        let rpc = try await driver.launch(codex.url, environment: codex.environment) { [processes] process in
            try await processes.admit(process, for: sessionID, admission)
        }
        host(driver, rpc)
        do {
            return try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: AgentRuntimeError.launchTimedOut(.codex)) { try await body(driver, rpc) }
        } catch {
            await rpc.shutdown()
            throw error as? CodexRPCError == .timedOut ? AgentRuntimeError.launchTimedOut(.codex) : error
        }
    }

    private func host(_ driver: CodexDriver, _ rpc: CodexRPC) {
        let pid = rpc.pid
        hosted[pid] = driver
        driver.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        driver.onEvent = { [weak self] event in self?.event(event, from: pid) }
        rpc.onRequest = { [weak self, weak rpc] method, id, params in
            guard let self, let rpc else { return false }
            return self.request(method, params, id: id, on: rpc)
        }
    }

    private func attachHosted(_ result: JSONValue, driver: CodexDriver, rpc: CodexRPC, launchToken: String?) -> Session.ID {
        var session = makeSession(result["thread"] ?? .object([:]), pid: rpc.pid)
        session.hosted = true
        session.fast = result["serviceTier"]?.string == "priority"
        session.launchToken = launchToken
        processes.adopt(rpc.process, as: session.sessionID)
        attach(session, driver: driver)
        return session.id
    }
}
#endif

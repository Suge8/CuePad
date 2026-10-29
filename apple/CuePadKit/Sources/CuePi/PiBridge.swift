#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

/// 本机所有活着的 Agent 会话，实时状态只在内存。每个会话有一条控制通道（`SessionLink`）：Pi 的由这里发现并连接（经扩展的 Unix socket），
/// 其他 Agent 的由各自的适配接上（`attach`、`update`、`detach`），界面、记录器与执行器只认这一处。
///
/// - Pi 会话出现 = 连上 socket 并收到 hello 快照；会话结束 = 连接断开（无心跳、无轮询）。
/// - 目录本身一变（kqueue，`DirectoryWatcher`）就重扫；启动时全量扫描一次。残留 socket（进程被强杀）按文件名里的 pid 判死后删除。
/// - 多个客户端（包括多个 `PiBridge`）可同时连同一会话：各自都收到 hello 与全部状态切换，
///   命令各走各的连接，`ack` 只回给发送方；扩展不做仲裁，命令按到达顺序交给 Pi。
@MainActor @Observable
public final class PiBridge {
    /// 一个在线会话一格。状态变化只改这一格，只有读这一格的视图重算；读 `slots` 的只在会话出现、消失时重算。
    @MainActor @Observable
    public final class Slot: Identifiable {
        /// 会话的身份与工作目录一经连上就不变：只读它们的视图（会话集合、归属项目）不随状态变化重算。
        public nonisolated let id: PiSession.ID
        public nonisolated let sessionID: String
        public nonisolated let cwd: URL
        public internal(set) var session: PiSession
        /// 此刻正在说的这条回答（见 `PiDraft`，刷新节奏见 `PiDraftFeed`）：出字时只有读它的视图重算
        public var draft: PiDraft? { feed.draft }
        /// 有正在说的话（`draft != nil`），只在有无变化时通知：会话行读它不随每个增量重算
        public var speaking: Bool { feed.speaking }
        private let feed = PiDraftFeed()

        init(_ session: PiSession) {
            id = session.id
            sessionID = session.sessionID
            cwd = session.cwd
            self.session = session
        }

        func offer(_ next: PiDraft?) { feed.offer(next) }
    }

    /// 在线会话的格子，按出现先后。界面读会话用这个（列表读 `slots`，每一行读自己那格的 `session`）或 `session(sessionID:)`。
    public internal(set) var slots: [Slot] = []

    /// 在线会话的快照（读了每一格，任何一格变化都会通知读它的视图）：非界面代码与测试用，视图别读。
    public var sessions: [PiSession] { slots.map(\.session) }

    /// 在线会话的文件，会话上线、下线（或换了文件）时给新的一份：历史索引另盯它们（`PiHistoryIndexer.events(following:)`）。
    public var sessionFiles: Observations<Set<URL>, Never> { Observations { Set(self.slots.compactMap(\.session.sessionFile)) } }

    /// 这个 Pi 会话（`sessionID`）在线的那个进程；同一会话开在两个进程里时取先出现的。只随这一个会话的变化通知。
    public func session(sessionID: String) -> PiSession? { slot(sessionID: sessionID)?.session }

    /// 这个会话（`sessionID`）在线的那一格，规则同 `session(sessionID:)`；只随会话出现、消失通知。
    public func slot(sessionID: String) -> Slot? { slots.first { $0.sessionID == sessionID } }

    public func session(id: PiSession.ID) -> PiSession? { slots.first { $0.id == id }?.session }

    @ObservationIgnored let directory: URL
    @ObservationIgnored let hostedIdle: Duration
    /// 显式结束正在等待的承载进程；让出后的接手重载不能干扰同一个结束请求。
    @ObservationIgnored private(set) var ending: Set<PiSession.ID> = []
    @ObservationIgnored var links: [String: Link] = [:]       // socket 文件名（不含 .sock）→ 连接
    /// 在线会话的控制通道（Pi 的就是它的 `Link`）
    @ObservationIgnored var controls: [PiSession.ID: any SessionLink] = [:]
    /// 重开前（`carryOver`）与重新载入扩展前（`detach` 的 `.reload`）各会话的状态与计时：重新上桥时用一次。
    /// 读不懂的扩展读不到状态，不留也不用：接回时沿用的是它之前读到的
    @ObservationIgnored var carried: [String: (state: PiWorkState, times: PiTimes)] = [:]
    /// 托管的会话歇着的计时（见 `reviewHosted`）
    @ObservationIgnored var idleTimers: [PiSession.ID: Task<Void, Never>] = [:]
    /// 已经请它退出的托管会话：同一个只请一次（Pi 收尾中再收到一次 SIGTERM 会跳过收尾直接退出）
    @ObservationIgnored var releasing: Set<PiSession.ID> = []
    /// 没告别就断开的会话：断开可能先于进程退出（强杀后还是僵尸），留着退出监视，退出时再删残留 socket
    @ObservationIgnored var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    /// 已报告不兼容的 socket 文件：同一个文件还在时不再重连、不重复报告。按文件本身认（不按名字）：
    /// /reload 在同一路径建的新 socket 名字不变，得照常去连
    @ObservationIgnored var incompatible: [String: PiSocketDirectory.FileIdentity] = [:]
    @ObservationIgnored var watcher: DirectoryWatcher?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<PiSessionChange>.Continuation] = [:]

    /// - Parameter hostedIdle: 托管的 Claude Code、Codex 会话歇着满这么久就请它退出（不算结束，发话时再接着）。
    public init(socketDirectory: URL = PiPaths().socketDirectory, hostedIdle: Duration = AgentTimeouts.hostedIdle) {
        directory = socketDirectory
        self.hostedIdle = hostedIdle
    }

    // MARK: 生命周期

    public func start() throws {
        guard watcher == nil else { return }
        try PiSocketDirectory.prepare(directory)
        watcher = try DirectoryWatcher(directory) { [weak self] in self?.scan() }
        scan()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        for link in links.values { link.connection.close() }
        links = [:]
        controls = [:]
        for timer in idleTimers.values { timer.cancel() }
        idleTimers = [:]
        for watcher in orphanExitWatchers.values { watcher.cancel() }
        orphanExitWatchers = [:]
        slots = []
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    /// 会话出现/状态切换/结束的事件流（每次调用得到独立的流）。
    public func changes() -> AsyncStream<PiSessionChange> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    func emit(_ change: PiSessionChange) {
        for continuation in subscribers.values { continuation.yield(change) }
        reviewHosted()
    }
}

extension PiBridge {
    /// 发消息（文字 + 图片），以这句开新一轮：会话歇着就直接开始，在跑就先打断这一轮；打断不了的（`AgentCapabilities.speakBlocked`）
    /// 拒收、带上原因，不排队。受理即返回，不代表模型成功。
    public func send(_ message: PiMessage, to id: PiSession.ID) async throws {
        let link = try control(id, needs: message.images.isEmpty ? [] : .images)
        guard let peer = session(id: id) else { throw PiBridgeError.sessionEnded }
        if case .cue(let deliveryID, let turnStartedAt) = message.policy {
            guard !peer.upgrading, peer.state != .ended, peer.state != .interrupted else { throw PiBridgeError.rejected("unconfirmed_turn") }
            if peer.state.hasPendingWork {
                guard let deliveryID, !deliveryID.isEmpty, let turnStartedAt, let current = peer.turnStartedAt else { throw PiBridgeError.rejected("unconfirmed_turn") }
                // 接入可能有亚毫秒，Store 往返只有毫秒；复用存储合同，不按任意容差放宽。
                guard turnStartedAt.stored == current.stored else { throw PiBridgeError.rejected("user_turn") }
            }
        }
        if let why = peer.capabilities.speakBlocked(in: peer.state, agent: peer.agent) {
            throw PiBridgeError.rejected("failed: \(why)")
        }
        try await link.send(message, in: id)
    }

    /// 执行一条斜杠命令（整行，以 / 开头）：Pi 的内置命令由扩展调 Pi 的接口做，扩展命令、提示词模板与 skill 由 Pi 派发；会开一轮的
    /// （模板与 skill 展开成这一轮的提示词）与 `send` 同一规则，在跑就先打断。Pi 转发的扩展命令没有公开完成回执，结果保持未确认；
    /// 清单里没有的命令抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .commands).command(line, in: id)
    }

    /// 让该会话从会话文件重新载入到最新（同一会话的另一个进程刚写过文件后）；扩展判断能否安全重载，不能就提示用户。只有 Pi 有。
    public func reload(_ id: PiSession.ID) async throws {
        try await pi(id).reload()
    }

    /// 结束该会话并等它下线；`AgentTimeouts.end` 内没下线抛 `notEnded`。
    public func end(_ id: PiSession.ID) async throws {
        guard let target = session(id: id) else { throw PiBridgeError.sessionEnded }
        let ids = target.agent == .pi
            ? sessions.filter { $0.agent == .pi && $0.sessionID == target.sessionID }.map(\.id) : [id]
        ending.formUnion(ids)
        defer { ending.subtract(ids) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await self.endInstance(id) } }
            try await group.waitForAll()
        }
    }

    private func endInstance(_ id: PiSession.ID) async throws {
        let link = try control(id, needs: .end)
        let changes = changes()  // 先订阅再动手：下线的那一刻不会漏
        try await link.end(id)
        try await withDeadline(AgentTimeouts.end, orThrow: PiBridgeError.notEnded) {
            for await change in changes {
                if case .ended(let ended, let reason) = change, ended.id == id {
                    if ended.agent == .pi, reason != .closed(reason: "quit") { throw PiBridgeError.notEnded }
                    return
                }
            }
            throw CancellationError()
        }
    }

    /// 停止该会话正在跑的这一轮（相当于在 Agent 里按 Esc）：受理即返回，会话随后歇下（`.settled`），能接着说。
    /// 已经空闲时什么也不发生（也成功）；只停它自己这一轮，它派出的子代理照常跑。
    public func abort(_ id: PiSession.ID) async throws {
        try await control(id, needs: .abort).abort(id)
    }

    /// 把该会话出错的那一轮原样重跑一遍（`PiSessionState.canRetry`）：对话里不多一句话、也不发"继续"，只多出新的回答。受理即返回，会话随即回到在跑；
    /// 会话在跑、或最后一轮不是出错结束的，抛 `rejected("nothing_to_retry")`。只有 Pi 有。
    public func retry(_ id: PiSession.ID) async throws {
        try await control(id, needs: .retry).retry(id)
    }

    /// 回答该会话正在等的弹窗；`promptID` 不是正在等的那个、或答案对不上时抛 `PiBridgeError.rejected`。
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .answer).answer(answer, to: promptID, in: id)
    }

    /// 换该会话的模型、思考强度或会话名（至少给一项，会话名不能是空白）：先换模型再设强度，强度按新模型支持的范围夹取。
    /// 模型不在 Agent 的模型表里抛 `unknownModel`，提供方没配好密钥抛 `rejected("no_auth")`；成功后会话的上报（`model`、`thinking`）随 `infoChanged` 更新。
    public func configure(model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, name: String? = nil, in id: PiSession.ID) async throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != nil || thinking != nil || name != nil, name?.isEmpty != true else { throw PiBridgeError.rejected("bad_request") }
        var needs: AgentCapabilities = model != nil || thinking != nil ? .model : []
        if name != nil { needs.insert(.rename) }
        try await control(id, needs: needs).configure(model: model, thinking: thinking, name: name, in: id)
    }

    /// 请该会话查一次所有 OAuth 订阅的额度：查到的随 `changes()` 的 `.quota` 报出（与回复里带回的同一条路），
    /// 再返回；有一家没查到抛 `rejected("failed: …")`（查到的那几家照常报出）。只有 Pi 有。
    public func refreshQuota(in id: PiSession.ID) async throws {
        try await pi(id).refreshQuota()
    }

    /// 会话的控制通道；这个 Agent 的这类会话做不到（`AgentCapabilities`）就抛 `unsupported`：能做什么只看能力表，通道不判断。
    private func control(_ id: PiSession.ID, needs: AgentCapabilities) throws -> any SessionLink {
        guard let link = controls[id], let session = session(id: id) else { throw PiBridgeError.unknownSession(id) }
        guard session.capabilities.isSuperset(of: needs) else { throw PiBridgeError.unsupported }
        return link
    }

    private func pi(_ id: PiSession.ID) throws -> Link {
        guard let link = controls[id] else { throw PiBridgeError.unknownSession(id) }
        guard let pi = link as? Link else { throw PiBridgeError.unsupported }
        return pi
    }
}
#endif

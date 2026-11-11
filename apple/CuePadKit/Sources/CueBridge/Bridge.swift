#if os(macOS)
import CueStore
import Foundation
import Observation

/// 各家经 attach/update/detach 发布，会话命令交给 `SessionLink`；Pi 的 socket 生命周期由 `PiConnections` 持有。
@MainActor @Observable
public final class Bridge {
    /// 一个在线会话一格。状态变化只改这一格，只有读这一格的视图重算；读 `slots` 的只在会话出现、消失时重算。
    @MainActor @Observable
    public final class Slot: Identifiable {
        /// 会话的身份与工作目录一经连上就不变：只读它们的视图（会话集合、归属项目）不随状态变化重算。
        public nonisolated let id: Session.ID
        public nonisolated let sessionID: String
        public nonisolated let cwd: URL
        public internal(set) var session: Session
        /// 出字时只有读它的视图重算
        public var draft: LiveDraft? { feed.draft }
        /// 只在有无变化时通知：会话行读它不随每个增量重算
        public var speaking: Bool { feed.speaking }
        private let feed = LiveDraftFeed()

        init(_ session: Session) {
            id = session.id
            sessionID = session.sessionID
            cwd = session.cwd
            self.session = session
        }

        func offer(_ next: LiveDraft?) { feed.offer(next) }
    }

    /// 界面读会话用这个（列表读 `slots`，每一行读自己那格的 `session`）或 `session(sessionID:)`。
    public internal(set) var slots: [Slot] = []

    /// 在线会话的快照（读了每一格，任何一格变化都会通知读它的视图）：非界面代码与测试用，视图别读。
    public var sessions: [Session] { slots.map(\.session) }

    public var sessionFiles: Observations<Set<URL>, Never> { Observations { Set(self.slots.compactMap(\.session.sessionFile)) } }

    /// 同一会话开在两个进程里时取先出现的。只随这一个会话的变化通知。
    public func session(sessionID: String) -> Session? { slot(sessionID: sessionID)?.session }

    /// 规则同 `session(sessionID:)`；只随会话出现、消失通知。
    public func slot(sessionID: String) -> Slot? { slots.first { $0.sessionID == sessionID } }

    public func session(id: Session.ID) -> Session? { slots.first { $0.id == id }?.session }

    @ObservationIgnored private let connections: PiConnections
    @ObservationIgnored let hostedIdle: Duration
    /// App 给的是它自己的那一个（`MacDependencies.timing`）。
    @ObservationIgnored let timing: Timing
    /// 显式结束正在等待的承载进程；让出后的接手重载不能干扰同一个结束请求。
    @ObservationIgnored private(set) var ending: Set<Session.ID> = []
    @ObservationIgnored var controls: [Session.ID: any SessionLink] = [:]
    /// 重开前（`carryOver`）与重新载入扩展前（`detach` 的 `.reload`）各会话的状态与计时：重新上桥时用一次。
    /// 读不懂的扩展读不到状态，不留也不用：接回时沿用的是它之前读到的
    @ObservationIgnored var carried: [String: (state: WorkState, times: SessionTimes)] = [:]
    @ObservationIgnored var idleTimers: [Session.ID: Task<Void, Never>] = [:]
    /// 已经请它退出的托管会话：同一个只请一次（Pi 收尾中再收到一次 SIGTERM 会跳过收尾直接退出）
    @ObservationIgnored var releasing: Set<Session.ID> = []
    @ObservationIgnored let turns = SessionGate()
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<SessionChange>.Continuation] = [:]

    /// - Parameter hostedIdle: 托管的 Claude Code、Codex 会话歇着满这么久就请它退出（不算结束，发话时再接着）。
    public init(socketDirectory: URL = PiPaths().socketDirectory, hostedIdle: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system) {
        self.hostedIdle = hostedIdle
        self.timing = timing
        connections = PiConnections(directory: socketDirectory)
        connections.bridge = self
    }

    public func start() throws { try connections.start() }

    public func offerExtensionUpgrade() { connections.offerExtensionUpgrade() }

    public func stop() {
        turns.stop()
        connections.stop()
        controls = [:]
        for timer in idleTimers.values { timer.cancel() }
        idleTimers = [:]
        slots = []
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    public func changes() -> AsyncStream<SessionChange> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    func emit(_ change: SessionChange) {
        for continuation in subscribers.values { continuation.yield(change) }
        reviewHosted()
    }
}

extension Bridge {
    /// 打断不了的（`AgentCapabilities.speakBlocked`）拒收、带上原因，不排队。受理即返回，不代表模型成功。
    /// 同一会话的 `send` 一次一句（`SessionGate`）；`abort` 不排队、还取消排着的发话；斜杠命令不排队（`/compact` 要等压完才确认，发话得能在它进行中打断它）。
    public func send(_ message: SessionMessage, to id: Session.ID) async throws {
        try await turns.run(id) { try await deliver(message, to: id) }
    }

    private func deliver(_ message: SessionMessage, to id: Session.ID) async throws {
        try Task.checkCancellation()
        let link = try control(id, needs: message.images.isEmpty ? [] : .images)
        guard let peer = session(id: id) else { throw BridgeError.sessionEnded }
        if case .cue(let deliveryID, let turnStartedAt) = message.policy {
            guard !peer.upgrading, peer.state != .ended, peer.state != .interrupted else { throw BridgeError.rejected("unconfirmed_turn") }
            if peer.state.hasPendingWork {
                guard let deliveryID, !deliveryID.isEmpty, let turnStartedAt, peer.turnStartedAt != nil else { throw BridgeError.rejected("unconfirmed_turn") }
                guard peer.isCurrentTurn(turnStartedAt.stored) else { throw BridgeError.rejected("user_turn") }
            }
        }
        if let why = peer.capabilities.speakBlocked(in: peer.state, agent: peer.agent) {
            throw BridgeError.rejected("failed: \(why)")
        }
        do { try await link.send(message, in: id) }
        catch BridgeError.upgradingExtension {
            throw BridgeError.operationStarted(ShownText(BridgeError.upgradingExtension))
        }
    }

    /// 整行以 / 开头。Pi 执行了它就确认（处理函数的结果没有公开回执）；模板与 skill 是说的话，经 `send` 交出。
    /// 模板与 skill 是说的话，经 `send` 交出。清单里没有的命令抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, deliveryID: String? = nil, in id: Session.ID) async throws {
        try await control(id, needs: .commands).command(line, deliveryID: deliveryID, in: id)
    }

    /// 同一会话的另一个进程刚写过文件后用；扩展判断能否安全重载，不能就提示用户。只有 Pi 有。
    public func reload(_ id: Session.ID) async throws {
        try await pi(id).reload()
    }

    /// `AgentTimeouts.end` 内没下线抛 `notEnded`。
    public func end(_ id: Session.ID) async throws {
        guard let target = session(id: id) else { throw BridgeError.sessionEnded }
        let ids = target.agent == .pi
            ? sessions.filter { $0.agent == .pi && $0.sessionID == target.sessionID }.map(\.id) : [id]
        ending.formUnion(ids)
        defer { ending.subtract(ids) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await self.endInstance(id) } }
            try await group.waitForAll()
        }
    }

    private func endInstance(_ id: Session.ID) async throws {
        let link = try control(id, needs: .end)
        let changes = changes()  // 先订阅再动手：下线的那一刻不会漏
        try await link.end(id)
        try await withDeadline(AgentTimeouts.end, timing: timing, orThrow: BridgeError.notEnded) {
            for await change in changes {
                if case .ended(let ended, let reason) = change, ended.id == id {
                    if ended.agent == .pi, reason != .closed(reason: "quit") { throw BridgeError.notEnded }
                    return
                }
            }
            throw CancellationError()
        }
    }

    /// 停止该会话正在跑的这一轮（相当于在 Agent 里按 Esc）：受理即返回，会话随后歇下（`.settled`），能接着说。
    /// 已经空闲时什么也不发生（也成功）；只停它自己这一轮，它派出的子代理照常跑。
    /// 有目标的停止不取消本桥排着的新消息；真实回合身份交给接收端同步核对。
    public func abort(_ id: Session.ID, deliveryID: String, turnStartedAt: Int64) async throws {
        guard session(id: id)?.isCurrentTurn(turnStartedAt) == true else { throw BridgeError.rejected("stale_turn") }
        try await control(id, needs: .abort).abort(id, deliveryID: deliveryID, turnStartedAt: turnStartedAt)
    }

    public func abort(_ id: Session.ID) async throws {
        let link = try control(id, needs: .abort)
        turns.abort(id)
        try await link.abort(id)
    }

    /// 把该会话出错的那一轮原样重跑一遍（`SessionState.canRetry`）：对话里不多一句话、也不发"继续"，只多出新的回答。受理即返回，会话随即回到在跑；
    /// 会话在跑、或最后一轮不是出错结束的，抛 `rejected("nothing_to_retry")`。只有 Pi 有。
    public func retry(_ id: Session.ID) async throws {
        try await control(id, needs: .retry).retry(id)
    }

    /// 回答该会话正在等的弹窗；`promptID` 不是正在等的那个、或答案对不上时抛 `BridgeError.rejected`。
    public func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws {
        try await control(id, needs: .answer).answer(answer, to: promptID, in: id)
    }

    /// 换该会话的模型、思考强度或会话名（至少给一项，会话名不能是空白）：先换模型再设强度，强度按新模型支持的范围夹取。
    /// 模型不在 Agent 的模型表里抛 `unknownModel`，提供方没配好密钥抛 `rejected("no_auth")`；成功后会话的上报（`model`、`thinking`）随 `infoChanged` 更新。
    public func configure(_ config: SessionConfig, in id: Session.ID) async throws {
        var config = config
        config.name = config.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.model != nil || config.thinking != nil || config.fast != nil || config.name != nil, config.name?.isEmpty != true else { throw BridgeError.rejected("bad_request") }
        var needs: AgentCapabilities = config.model != nil || config.thinking != nil || config.fast != nil ? .model : []
        if config.name != nil { needs.insert(.rename) }
        try await control(id, needs: needs).configure(config, in: id)
    }

    /// 请该会话查一次所有 OAuth 订阅的额度：查到的随 `changes()` 的 `.quota` 报出（与回复里带回的同一条路），
    /// 再返回；有一家没查到抛 `rejected("failed: …")`（查到的那几家照常报出）。只有 Pi 有。
    public func refreshQuota(in id: Session.ID) async throws {
        try await pi(id).refreshQuota()
    }

    /// 不在桥上的为 false。
    public func isTurnRunning(_ id: Session.ID) -> Bool { session(id: id)?.state.isTurnRunning ?? false }

    /// 会话的控制通道；这个 Agent 的这类会话做不到（`AgentCapabilities`）就抛 `unsupported`：能做什么只看能力表，通道不判断。
    private func control(_ id: Session.ID, needs: AgentCapabilities) throws -> any SessionLink {
        guard let link = controls[id], let session = session(id: id) else { throw BridgeError.unknownSession(id) }
        guard session.capabilities.isSuperset(of: needs) else { throw BridgeError.unsupported }
        return link
    }

    private func pi(_ id: Session.ID) throws -> PiConnection {
        guard let link = controls[id] else { throw BridgeError.unknownSession(id) }
        guard let pi = link as? PiConnection else { throw BridgeError.unsupported }
        return pi
    }
}
#endif

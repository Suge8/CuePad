#if os(macOS)
import CueStore
import Foundation
import Observation

@MainActor @Observable
public final class Bridge {
    @MainActor @Observable
    public final class Slot: Identifiable {
        public nonisolated let id: Session.ID
        public nonisolated let sessionID: String
        public nonisolated let cwd: URL
        public internal(set) var session: Session
        public var draft: LiveDraft? { feed.latest }
        public var speaking: Bool { feed.speaking }
        private let feed = LiveDraftFeed()

        init(_ session: Session) {
            id = session.id
            sessionID = session.sessionID
            cwd = session.cwd
            self.session = session
        }

        func offer(_ next: LiveDraft?) { feed.offer(next) }
        func roundStopped() { feed.roundStopped() }
    }

    public internal(set) var slots: [Slot] = []

    public var sessions: [Session] { slots.map(\.session) }

    public var sessionFiles: Observations<Set<URL>, Never> { Observations { Set(self.slots.compactMap(\.session.sessionFile)) } }

    public func session(sessionID: String) -> Session? { slot(sessionID: sessionID)?.session }

    public func slot(sessionID: String) -> Slot? { slots.first { $0.sessionID == sessionID } }

    public func session(id: Session.ID) -> Session? { slots.first { $0.id == id }?.session }

    @ObservationIgnored private let connections: PiConnections
    @ObservationIgnored let hostedIdle: Duration
    @ObservationIgnored let timing: Timing
    @ObservationIgnored let paths: AgentPaths?
    @ObservationIgnored var controls: [Session.ID: any SessionLink] = [:]
    @ObservationIgnored var carried: [String: (state: WorkState, times: SessionTimes)] = [:]
    @ObservationIgnored var idleTimers: [Session.ID: Task<Void, Never>] = [:]
    /// 已经请它退出的托管会话：同一个只请一次（Pi 收尾中再收到一次 SIGTERM 会跳过收尾直接退出）
    @ObservationIgnored var releasing: Set<Session.ID> = []
    @ObservationIgnored let turns = SessionGate()
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<SessionChange>.Continuation] = [:]

    public init(
        socketDirectory: URL = PiPaths().socketDirectory, paths: AgentPaths? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system
    ) {
        self.hostedIdle = hostedIdle
        self.timing = timing
        self.paths = paths
        connections = PiConnections(directory: socketDirectory, timing: timing)
        connections.bridge = self
    }

    public func start() throws { try connections.start() }

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
    /// 受理即返回，不代表模型成功。
    /// 同一会话的 `send` 一次一句（`SessionGate`）；`abort` 不排队、还取消排着的发话；斜杠命令不排队（`/compact` 要等压完才确认，发话得能在它进行中打断它）。
    public func send(_ message: SessionMessage, to id: Session.ID) async throws {
        try await turns.run(id) { try await deliver(message, to: id) }
    }

    private func deliver(_ message: SessionMessage, to id: Session.ID) async throws {
        try Task.checkCancellation()
        let link = try control(id, needs: message.images.isEmpty ? [] : .images)
        guard let peer = session(id: id) else { throw BridgeError.sessionEnded }
        if message.policy == .cue {
            guard !peer.upgrading, peer.state != .ended, peer.state != .interrupted else { throw BridgeError.rejected("unconfirmed_turn") }
            if peer.state.hasPendingWork {
                guard let opener = peer.turnOpener else { throw BridgeError.rejected("unconfirmed_turn") }
                guard opener.cue else { throw BridgeError.rejected("user_turn") }
            }
        }
        do { try await link.send(message, in: id) }
        catch BridgeError.upgradingExtension {
            throw BridgeError.operationStarted(ShownText(BridgeError.upgradingExtension))
        }
    }

    /// 整行以 / 开头（不是抛 `rejected("bad_request")`）。Pi 执行了它就确认（处理函数的结果没有公开回执）；模板与 skill 是说的话，经 `send` 交出。
    /// 会话报的命令清单（`Session.commands`）里没有的抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, opener: TurnOpener? = nil, in id: Session.ID) async throws {
        let link = try control(id)
        let name = try SlashLine(line).name
        guard session(id: id)?.commands.contains(where: { $0.name == name }) == true else { throw BridgeError.rejected("unknown_command") }
        try await link.command(line, opener: opener, in: id)
    }

    public func end(_ id: Session.ID) async throws {
        guard let target = session(id: id) else { throw BridgeError.sessionEnded }
        let ids = target.agent == .pi
            ? sessions.filter { $0.agent == .pi && $0.sessionID == target.sessionID }.map(\.id) : [id]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try await self.endInstance(id) } }
            try await group.waitForAll()
        }
    }

    private func endInstance(_ id: Session.ID) async throws {
        let link = try control(id)
        let changes = changes()
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

    public func abort(_ id: Session.ID) async throws {
        let link = try control(id)
        turns.abort(id)
        try await link.abort(id)
    }

    public func retry(_ id: Session.ID) async throws {
        try await control(id, needs: .retry).retry(id)
    }

    public func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws {
        try await control(id).answer(answer, to: promptID, in: id)
    }

    public func configure(_ config: SessionConfig, in id: Session.ID) async throws {
        var config = config
        config.name = config.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.model != nil || config.thinking != nil || config.fast != nil || config.name != nil, config.name?.isEmpty != true else { throw BridgeError.rejected("bad_request") }
        let link = try control(id)
        if config.fast == true, let session = session(id: id) {
            let target = if let model = config.model { session.availableModels.first { $0.key == model } } else { session.model }
            guard target?.supportsFast == true else { throw BridgeError.unsupported }
        }
        try await link.configure(config, in: id)
    }

    public func refreshQuota(in id: Session.ID) async throws {
        try await control(id, needs: .quota).refreshQuota(in: id)
    }

    public func isTurnRunning(_ id: Session.ID) -> Bool { session(id: id)?.state.isTurnRunning ?? false }

    private func control(_ id: Session.ID, needs: AgentCapabilities = []) throws -> any SessionLink {
        guard let link = controls[id], let session = session(id: id) else { throw BridgeError.unknownSession(id) }
        guard session.capabilities.isSuperset(of: needs) else { throw BridgeError.unsupported }
        return link
    }
}
#endif

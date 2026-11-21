#if os(macOS)
import CueStore
import Foundation
import OSLog

/// 服务不续传，所以每次连上（含断线重连）都重拉一遍快照。
/// 只管 CuePad 开的、接着的会话：服务与库是用户的，别处开的会话（终端、Cue 的大脑）也在里面，一概不上桥、不进索引、不收事件。
/// 认法是资料库里这台 Mac 托管过的（`CueStore.hostedSessionIDs`，App 重启、服务重连后靠它认回）加上这次运行里开的、接着的（`sessions`）。
/// 在线：服务活着期间有过活动（建立、发话、执行、提问）的托管会话在线——连上时按“最后修改晚于服务启动”认，之后按事件认；在 CuePad 里结束的会话也下线，直到它再有活动。
/// 从没取过模型表的第一次启动，它先用随包的旧表、同时联网取新表（约 1～2 秒）；这期间配置的默认模型不在旧表里就改用旧表第一个（它自己的终端界面也一样）。CuePad 不补，会话页显示实际用的模型。
@MainActor
public final class OpenCodeRuntime: AgentRuntime, SessionLink {
    static let log = Logger(subsystem: AppIdentity.id, category: "opencode")
    static let allowOnce = String(localized: "允许"), allowAlways = String(localized: "总是允许"), reject = String(localized: "拒绝")

    let bridge: Bridge
    let paths: AgentPaths
    let store: CueStore
    let hostID: String
    let brief: String
    let opencode: @Sendable () async -> URL?
    let locate: @Sendable () async -> ExecutableLocator
    let transcriptWindow: TimeInterval
    let timing: Timing

    private var watcher: FileFollower?
    private var watching: Task<Void, Never>?
    var connection: Connection?
    var waiters: [UUID: CheckedContinuation<Connection, any Error>] = [:]

    var sessions: [String: Tracked] = [:]
    var parents: [String: String] = [:]
    var childTurns: [String: OpenCodeTurn] = [:]
    var ended: [String: Date] = [:]
    var catalogs: [String: Catalog] = [:]
    var checkpoints: [String: OpenCodeHistory.Checkpoint] = [:]
    var ingestQueue: [String] = []
    var ingesting: Task<Void, Never>?
    var startedService: (executable: URL, environment: [String: String])?

    @MainActor final class Connection {
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

    struct Catalog {
        var models: [OpenCodeModel]
        var commands: [SlashCommand]
    }

    @MainActor struct Tracked {
        var info: OpenCodeSessionInfo
        var online = false
        var launchToken: String?
        let turns: HostedTurns
        var parser = OpenCodeTurn()
        var context: ContextUsage?
        var firstMessage: String?

        var directory: String { info.location.directory }
        var facts: SessionFacts {
            get { turns.facts }
            nonmutating set { turns.facts = newValue }
        }
    }

    func track(_ info: OpenCodeSessionInfo) -> Tracked {
        if let tracked = sessions[info.id] { return tracked }
        let turns = HostedTurns(timing: timing)
        turns.onChange = { [weak self] in self?.publish(info.id) }
        return Tracked(info: info, turns: turns)
    }

    public init(
        bridge: Bridge, paths: AgentPaths, store: CueStore, hostID: String, brief: String, opencode: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        transcriptWindow: TimeInterval = .infinity, timing: Timing = .system
    ) {
        self.timing = timing
        self.bridge = bridge
        self.paths = paths
        self.store = store
        self.hostID = hostID
        self.brief = brief
        self.opencode = opencode
        self.locate = locate
        self.transcriptWindow = transcriptWindow
    }

    public func start() throws {
        let watcher = FileFollower()
        watcher.follow(only: [paths.openCodeService.realPath.path])
        self.watcher = watcher
        watching = Task { [weak self] in
            for await _ in watcher.paths { self?.refresh() }
        }
        refresh()
    }

    public var hostedSessionsOutliveApp: Bool { startedService == nil }

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

    private func stopStartedService() -> @concurrent @Sendable () async -> Void {
        guard let service = startedService else { return {} }
        startedService = nil
        let timing = timing
        return { _ = await ChildProcess.run(service.executable, ["service", "stop"], environment: service.environment, timeout: AgentTimeouts.end, timing: timing) }
    }

    func refresh() {
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

    private func disconnect() {
        guard let connection else { return }
        close(connection)
        self.connection = nil
        for (id, tracked) in sessions {
            tracked.turns.closed()
            if tracked.online { bridge.detach(bridgeID(id, connection), reason: .disconnected) }
        }
        sessions = [:]
        parents = [:]
        childTurns = [:]
        ended = [:]
        catalogs = [:]
        ingestQueue = []
    }

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
            connection.ready = false
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            delay = min(delay * 2, Self.retryCeiling)
        }
    }

    private static let retryFloor: Duration = .seconds(1)
    private static let retryCeiling: Duration = .seconds(30)
}
#endif

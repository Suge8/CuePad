#if os(macOS)
import CueStore
import Foundation
import OSLog

/// 服务不续传，所以每次连上（含断线重连）都重拉一遍快照。
/// 在线：服务活着期间有过活动（建立、发话、执行、提问）的顶层会话在线——连上时按“最后修改晚于服务启动”认，之后按事件认；在 CuePad 里结束的会话也下线，直到它再有活动。服务端不知道终端的 tty，所以跳不到终端。
/// Cue 的大脑（`OpenCodeBrain`）开的会话也在用户的库里，按标记（`OpenCodeSessionInfo.isCueBrain`）跳过：它们由大脑自己的服务跑，事件不经后台服务的事件流，接入只会在会话列表与按 id 取会话时碰到。
/// 从没取过模型表的第一次启动，它先用随包的旧表、同时联网取新表（约 1～2 秒）；这期间配置的默认模型不在旧表里就改用旧表第一个（它自己的终端界面也一样）。CuePad 不补，会话页显示实际用的模型。
@MainActor
public final class OpenCodeRuntime: AgentRuntime, SessionLink {
    static let log = Logger(subsystem: AppIdentity.id, category: "opencode")
    static let allowOnce = String(localized: "允许"), allowAlways = String(localized: "总是允许"), reject = String(localized: "拒绝")

    let bridge: PiBridge
    let paths: AgentPaths
    let store: CueStore
    let hostID: String
    let opencode: @Sendable () async -> URL?
    let locate: @Sendable () async -> ExecutableLocator
    let transcriptWindow: TimeInterval
    let timing: Timing

    private var watcher: FileFollower?
    private var watching: Task<Void, Never>?
    var connection: Connection?
    var stopPhases: [PiSession.ID: StopPhase] = [:]
    var waiters: [UUID: CheckedContinuation<Connection, any Error>] = [:]

    var sessions: [String: Tracked] = [:]
    var parents: [String: String] = [:]
    var childTurns: [String: OpenCodeTurn] = [:]
    var ended: [String: Date] = [:]
    var catalogs: [String: Catalog] = [:]
    /// 服务里全部顶层会话（会话索引对账用）；还没拉到完整列表时为 nil
    var listed: Set<String>?
    var checkpoints: [String: OpenCodeHistory.Checkpoint] = [:]
    var ingestQueue: [String] = []
    var ingesting: Task<Void, Never>?
    /// CuePad 拉起的服务（它的 `opencode` 与环境），停止接入时由 CuePad 停掉；本来就在跑的为 nil
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
        var commands: [PiSlashCommand]
    }

    struct Tracked {
        var info: OpenCodeSessionInfo
        var online = false
        var hosted = false
        var launchToken: String?
        var facts = SessionFacts()
        var turn = OpenCodeTurn()
        var context: PiContextUsage?
        var firstMessage: String?

        var directory: String { info.location.directory }
    }

    public init(
        bridge: PiBridge, paths: AgentPaths, store: CueStore, hostID: String, opencode: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        transcriptWindow: TimeInterval = .infinity, timing: Timing = .system
    ) {
        self.timing = timing
        self.bridge = bridge
        self.paths = paths
        self.store = store
        self.hostID = hostID
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

    /// 会话在服务里：本来就在跑的服务 App 退出时不动，CuePad 拉起的那个由 `stop()` 停掉，会话随之下线。
    public var hostedSessionsOutliveApp: Bool { startedService == nil }

    /// 停下后可再 `start()`（接入开关关了又开）：会话下桥，读到哪的缓存一并丢掉——索引随断开接入删了，再接入从头读。
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

    /// 停掉 CuePad 拉起的服务（`opencode service stop`，它删掉登记文件，会话随之下线）；本来就在跑的不动。
    public func stopStartedService() -> @concurrent @Sendable () async -> Void {
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
        for (id, tracked) in sessions where tracked.online { bridge.detach(bridgeID(id, connection), reason: .disconnected) }
        sessions = [:]
        parents = [:]
        childTurns = [:]
        ended = [:]
        catalogs = [:]
        listed = nil
        ingestQueue = []
    }

    /// 服务“又能连了”没有事件可等，所以按退避重试：间隔从 1 秒翻倍到 30 秒，连上并拉完快照后复位。
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
            // 事件流断了：到重新拉完快照之前，状态不再是最新的，命令要等重连（`ensureService`）
            connection.ready = false
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            delay = min(delay * 2, Self.retryCeiling)
        }
    }

    private static let retryFloor: Duration = .seconds(1)
    private static let retryCeiling: Duration = .seconds(30)
}
#endif

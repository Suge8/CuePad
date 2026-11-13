import CueStore
import CueSync
import Foundation

/// 同步的状态（通不通、文件在路上、冲突）、立即同步与按节奏的拉取。拉不拉、多快由建它时给的 `cadence` 定（`AppServices.pollingCadence`）。
@Observable
final class SyncDriver {
    private(set) var state: SyncState
    /// key 离开就是那一趟结束了；文件在不在本机看附件目录。
    private(set) var fileTransfers: [String: FileTransfer] = [:]
    private(set) var conflicts: [CardConflict] = []
    /// 还没返回的立即同步有几个（`syncNow`）。
    private var syncNowWaits = 0
    var isSyncingNow: Bool { syncNowWaits > 0 }

    @ObservationIgnored let engine: (any SyncControlling)?
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let speechClock: SpeechClock
    @ObservationIgnored private let localHost: String?
    @ObservationIgnored private let tasks: Followers
    /// iOS 整个进后台时取消、回前台再开。
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var connected = false
    @ObservationIgnored private let cadence: @MainActor () -> SyncPoller.Cadence?
    /// 通断变了要跟着做的、不归同步管的事（`AppServices.syncStatusChanged`）。
    @ObservationIgnored private let statusChanged: @MainActor (SyncStatus) -> Void
    @ObservationIgnored private let report: @MainActor (AppServices.StartupIssue) -> Void

    init(
        engine: (any SyncControlling)?, status: SyncStatus, store: CueStore, timing: Timing, speechClock: SpeechClock, localHost: String?, tasks: Followers,
        cadence: @escaping @MainActor () -> SyncPoller.Cadence?, statusChanged: @escaping @MainActor (SyncStatus) -> Void,
        report: @escaping @MainActor (AppServices.StartupIssue) -> Void
    ) {
        self.engine = engine
        self.cadence = cadence
        self.statusChanged = statusChanged
        self.report = report
        state = SyncState(status: status, issues: [])
        self.store = store
        self.timing = timing
        self.speechClock = speechClock
        self.localHost = localHost
        self.tasks = tasks
    }

    /// 启动后的第一次拉走立即同步（`CloudSync.start` 自己不拉；拉取等得到同步开始）：算在 `isCatchingUp` 里，打开的页面知道手里的可能不是最新。
    func startSync() {
        guard let engine else { return }
        connectSync()
        tasks.add {
            for await state in engine.stateUpdates { self.apply(state) }
        }
        tasks.add {
            for await transfers in engine.fileTransfers { self.fileTransfers = transfers }
        }
        tasks.add {
            do {
                for try await conflicts in self.store.observe({ try $0.conflicts() }) { self.conflicts = conflicts }
            } catch where !Task.isCancelled {
                self.report(.syncUnavailable(String(localized: "冲突列表读取失败：\(String(describing: error))")))
            } catch {}
        }
        startPolling()
    }

    /// 认账号并开始第一拉（算在立即同步里），只做一次。当场在主线程之外开始：跟随者要等主线程建完第一帧才跑，挂在它们上面的第一拉跟着晚
    /// （iOS 模拟器实测晚 0.8–1.1 秒）。Mac 在建窗口之前就调：建窗口占着主线程 0.3–0.4 秒，这期间第一拉已在路上；`startSync` 里再调不重复。
    func connectSync() {
        guard let engine, !connected else { return }
        connected = true
        Task { @concurrent in await engine.start() }
        beginSyncNow()
    }

    /// 同步从不通变通时立即同步一次：断网时没传上去的记录当场传出、在等的回执当场拉回，不等发送者的退避。
    private func apply(_ new: SyncState) {
        let recovered = new.status.reachesMac && speechClock.moment.reachableSince == nil
        if new.status != state.status { statusChanged(new.status) }
        state = new
        speechClock.setReachable(new.status.reachesMac)
        if recovered { Task { await syncNow() } }
    }

    /// 换账号或清除资料：重置同步令牌的决定已做出，之前的对账结论当场作废。
    func resolve(_ resolution: SyncResolution) async throws {
        state.reconciled = false
        try await engine?.resolve(resolution)
    }

    /// Mac 不收推送，别的设备写来的东西只靠它；手机有推送，它是推送之外让在等的东西更快、更稳地到。已经在拉就不重开。
    /// 节奏与拉取不在主线程上：主线程忙（排版、重读）时拉取不跟着晚，只有等待理由变了才回主线程算一次节奏。
    func startPolling() {
        guard engine != nil, polling == nil else { return }
        let waiting = pollingCondition()
        let poller = SyncPoller(timing: timing)
        polling = Task {
            await poller.run(while: waiting) { await self.pull() }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// 不碰立即同步的忙碌状态（`syncNow`）。不在调用方的线程上跑（`@concurrent`）：从主线程来的也当场离开，主线程忙时拉取不跟着晚。
    /// 失败（多半是离线、被限流）由同步层归类、定下次的时刻并按段记日志，这里不另记：下一次触发或等待结束会再拉，状态变化经同步状态反映。
    @concurrent func pull() async {
        _ = try? await engine?.syncNow()
    }

    /// 本机同步恢复时（`Speech.Moment.reachableSince` 换了）也重给一次，
    /// 拉取从头开始一个窗口：断网超过手机的两分钟窗口，恢复后在等的回执照样拉得回来。断网时照常拉，拉成功就是恢复了（`SyncStatus.offline`）。
    func pollingCondition() -> AsyncStream<SyncPoller.Cadence?> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                // 依赖的状态变了节奏不一定变（如 Cue 在想与空闲之间来回）：同样的节奏不再给，免得拉取循环每次都从头立即拉
                var last: Polling?
                for await polling in Observations({ Polling(cadence: self.cadence(), since: self.speechClock.moment.reachableSince) })
                where last != polling && (last?.cadence != polling.cadence || polling.since != nil) {
                    last = polling
                    continuation.yield(polling.cadence)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Polling: Equatable {
        var cadence: SyncPoller.Cadence?
        var since: Date?
    }

    /// 最多等 `syncWaitLimit` 就返回，下拉刷新的圈、"立即同步"按钮不跟着网络一直转；没做完的在后台接着做。
    /// 每一次都要自己的一拉，不等还没返回的那次：那一拉可能开拉在这次之前，其间到服务器的改动就漏了，之后只剩按节奏的拉取
    /// （恢复连通时自动的那次还没收尾、你就下拉刷新，回执就这样没回来）。叠在一起的由拉取层合成在途那一拉之后的一拉（`CloudSync.syncNow`）。
    func syncNow() async {
        guard engine != nil else { return }
        await beginSyncNow().value
    }

    /// 拉取当场在主线程之外开始，不排在主线程的队列后面。
    @discardableResult
    private func beginSyncNow() -> Task<Void, Never> {
        let (settled, settle) = AsyncStream<Void>.makeStream()
        Task { @concurrent in
            await self.pull()
            settle.finish()
        }
        let deadline = Task { [timing] in
            try? await timing.sleep(Self.syncWaitLimit)
            settle.finish()
        }
        syncNowWaits += 1
        return Task {
            for await _ in settled {}
            deadline.cancel()
            syncNowWaits -= 1
        }
    }

    static let syncWaitLimit = Duration.seconds(5)

    /// "同步中"只有这一个来源。上传不算：那是本机的改动在往外走。
    /// 按节奏的拉取与收到推送的拉取也不算：它们一拉就完，算上的话页头每几秒闪一次。
    var isCatchingUp: Bool { isSyncingNow || state.catchingUp }

    /// 换新 Mac、还没对完时为 false：这时库里没有 Cue 不等于哪台都没设过。
    var knowsSyncedFacts: Bool {
        switch state.status {
        case .unavailable, .noAccount, .accountRestricted: true
        default: state.reconciled
        }
    }

    /// 本机就是它时库里就是最新的，不用等（Mac）。
    func isCatchingUp(on host: String?) -> Bool {
        isCatchingUp && (localHost == nil || host != localHost)
    }

    /// 只有要当场生效的请求（停止、改名、补对话）看它。说的话不看：写下就排着，恢复后自动发出。
    var reachesHost: Bool {
        #if os(iOS)
        speechClock.moment.reachableSince != nil  // 演示 Mac 在本机库里接手时一直算通（`SpeechClock`）
        #else
        true
        #endif
    }

    #if os(iOS)
    var macAlert: SyncSummary? {
        state.status.reachesMac ? nil : SyncSummary(state.status)
    }
    #endif

    var isSyncBusy: Bool {
        if isSyncingNow { return true }
        switch state.status {
        case .starting, .syncing: return true
        default: return false
        }
    }

    /// 没登录、受限时按了什么都不会发生，所以不给；上一次立即同步还没返回时照给、只停用，一按一松不让一行出现又消失。
    var canSyncNow: Bool {
        guard engine != nil else { return false }
        switch state.status {
        case .needsDecision, .outdated, .noAccount, .accountRestricted: return false
        default: return true
        }
    }

    /// 这个附件文件在本机的位置：没有就现在从 iCloud 取（手机上大文件、按流量计费时不自动取，用到时走这里）；没有同步（隔离库）抛 `FileFetchFailure.notSyncing`。
    func fetchFile(_ key: String) async throws -> URL { try await engine.fetchFile(key) }
}

nonisolated extension SyncStatus {
    /// 已连上或正在连接。
    var reachesMac: Bool {
        switch self {
        case .starting, .idle, .syncing: true
        default: false
        }
    }
}

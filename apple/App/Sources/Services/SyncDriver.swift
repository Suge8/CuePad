import CueStore
import CueSync
import Foundation

@Observable
final class SyncDriver {
    private(set) var state: SyncState
    private(set) var fileTransfers: [String: FileTransfer] = [:]
    private(set) var conflicts: [CardConflict] = []
    private var syncNowWaits = 0 { didSet { followLasting() } }
    var isSyncingNow: Bool { syncNowWaits > 0 }
    private let catchUp = Lasting()
    private let round = Lasting()
    var syncLasting: Bool { round.value }

    @ObservationIgnored let engine: (any SyncControlling)?
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let speechClock: SpeechClock
    @ObservationIgnored private let localHost: String?
    @ObservationIgnored private let tasks: Followers
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var connected = false
    @ObservationIgnored private let cadence: @MainActor () -> SyncPoller.Cadence?
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

    func connectSync() {
        guard let engine, !connected else { return }
        connected = true
        Task { @concurrent in await engine.start() }
        beginSyncNow()
    }

    private func apply(_ new: SyncState) {
        let recovered = new.status.reachesMac && speechClock.moment.reachableSince == nil
        if new.status != state.status { statusChanged(new.status) }
        state = new
        followLasting()
        speechClock.setReachable(new.status.reachesMac)
        if recovered { Task { await syncNow() } }
    }

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

    @concurrent func pull() async {
        _ = try? await engine?.syncNow()
    }

    func pollingCondition() -> AsyncStream<SyncPoller.Cadence?> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
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

    func syncNow() async {
        guard engine != nil else { return }
        await beginSyncNow().value
    }

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

    private func followLasting() {
        catchUp.follow(isCatchingUp)
        round.follow(state.status == .syncing)
    }

    var isCatchingUp: Bool { isSyncingNow || state.catchingUp }

    var knowsSyncedFacts: Bool {
        switch state.status {
        case .unavailable, .noAccount, .accountRestricted: true
        default: state.reconciled
        }
    }

    func isCatchingUp(on host: String?) -> Bool {
        isCatchingUp && (localHost == nil || host != localHost)
    }

    var showsCatchingUp: Bool { catchUp.value }
    func showsCatchingUp(on host: String?) -> Bool { catchUp.value && isCatchingUp(on: host) }

    var reachesHost: Bool {
        #if os(iOS)
        speechClock.moment.reachableSince != nil
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

    var canSyncNow: Bool {
        guard engine != nil else { return false }
        switch state.status {
        case .needsDecision, .outdated, .noAccount, .accountRestricted: return false
        default: return true
        }
    }

    func fetchFile(_ key: String) async throws -> URL { try await engine.fetchFile(key) }
}

nonisolated extension SyncStatus {
    var reachesMac: Bool {
        switch self {
        case .starting, .idle, .syncing: true
        default: false
        }
    }
}

@Observable
private final class Lasting {
    private(set) var value = false
    @ObservationIgnored private var clock: Task<Void, Never>?

    func follow(_ active: Bool) {
        guard active else {
            clock?.cancel()
            clock = nil
            if value { value = false }
            return
        }
        guard !value, clock == nil else { return }
        clock = Task {
            guard (try? await Task.sleep(for: Pending.delay)) != nil else { return }
            clock = nil
            value = true
        }
    }
}

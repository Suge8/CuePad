import CueStore
import CueSync
import Foundation

extension AppServices {
    /// `.iCloud` 不创建同步的两种情况：隔离模式（`CUEPAD_LIBRARY_DIR`，开发与验收用，不能碰真实账号的云端数据；
    /// 例外只有同步测量：Debug 构建、开发环境签名、给了 `-CuePadCloudKit YES`，见 `DebugHooks.syncsIsolatedLibrary`）；
    /// 本机 ad-hoc 构建没有 iCloud 权限（CloudKit 缺权限时会直接抛 ObjC 异常使进程崩溃，只有签名构建才有）。
    static func makeSync(
        _ source: SyncSource, store: CueStore, location: LibraryLocation
    ) -> (engine: (any SyncControlling)?, status: SyncStatus) {
        let reason: String
        switch source {
        case .custom(let sync): return (sync, .starting)
        case .built(let make): return (make(store), .starting)
        case .iCloud where location.isIsolated && !DebugHooks.syncsIsolatedLibrary: reason = String(localized: "开发用的隔离资料库，不连 iCloud")
        case .iCloud where !Entitlements.hasCloudKit: reason = String(localized: "这个构建没有 iCloud 权限（本机开发构建），不会同步")
        case .iCloud: return (DebugHooks.cloudSync(store), .starting)
        }
        log.notice("同步未启用：\(reason, privacy: .public)")
        return (nil, .unavailable(reason))
    }

    /// 启动后的第一次拉走立即同步（`CloudSync.start` 自己不拉；拉取等得到同步开始）：算在 `isCatchingUp` 里，打开的页面知道手里的可能不是最新。
    func startSync() {
        guard let sync else { return }
        connectSync()
        follow {
            for await state in sync.stateUpdates { self.setSyncState(state) }
        }
        follow {
            for await transfers in sync.fileTransfers { self.setFileTransfers(transfers) }
        }
        follow(reporting: { .syncUnavailable(String(localized: "冲突列表读取失败：\(String(describing: $0))")) }) {
            for try await conflicts in self.store.observe({ try $0.conflicts() }) { self.setConflicts(conflicts) }
        }
        #if os(macOS)
        startWakeSync()
        holdActivityWhilePolling()
        #endif
        startPolling()
    }

    /// 认账号并开始第一拉（算在立即同步里），只做一次。当场在主线程之外开始：跟随者要等主线程建完第一帧才跑，挂在它们上面的第一拉跟着晚
    /// （iOS 模拟器实测晚 0.8–1.1 秒）。Mac 在建窗口之前就调：建窗口占着主线程 0.3–0.4 秒，这期间第一拉已在路上；`startSync` 里再调不重复。
    func connectSync() {
        guard let sync, !syncConnected else { return }
        syncConnected = true
        Task { @concurrent in await sync.start() }
        beginSyncNow()
    }

    /// 回到前台的唯一入口；已经在做的不重开。
    func handleActivation() async {
        startPolling()
        relay?.resume()
        await sync?.activated()
        await syncNow()
    }

    /// Mac 不收推送，别的设备写来的东西只靠它；手机有推送，它是推送之外让在等的东西更快、更稳地到。已经在拉就不重开。
    /// 节奏与拉取不在主线程上：主线程忙（排版、重读）时拉取不跟着晚，只有等待理由变了才回主线程算一次节奏。
    func startPolling() {
        guard sync != nil, polling == nil else { return }
        let waiting = pollingCondition()
        let poller = SyncPoller(timing: timing)
        polling = Task {
            await poller.run(while: waiting) { await self.pull() }
        }
    }

    /// 不碰立即同步的忙碌状态（`syncNow`）。不在调用方的线程上跑（`@concurrent`）：从主线程来的也当场离开，主线程忙时拉取不跟着晚。
    /// 失败（多半是离线、被限流）由同步层归类、定下次的时刻并按段记日志，这里不另记：下一次触发或等待结束会再拉，状态变化经同步状态反映。
    @concurrent func pull() async {
        _ = try? await sync?.syncNow()
    }

    /// nil：不拉。"是否在等"只在这里定义；门铃通着（`doorbellFallback`）时降为兜底。
    /// Mac 以桥上连着的会话为准，资料库里的状态记录可能是没来得及标为结束的旧会话；Mac 不收推送（docs/sync.md「Agent 与 Cue 的通知」）。
    var pollingCadence: SyncPoller.Cadence? {
        #if os(macOS)
        DebugHooks.pollsLikePhone
            ? .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: true, doorbell: doorbellFallback)
            : .mac(waiting: hasOpenDeliveries || !pi.slots.isEmpty || cue.onDuty, doorbell: doorbellFallback)
        #else
        .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: piViewers > 0 || cueViewers > 0, doorbell: doorbellFallback)
        #endif
    }

    /// 本机同步恢复时（`Speech.Moment.reachableSince` 换了）也重给一次，
    /// 拉取从头开始一个窗口：断网超过手机的两分钟窗口，恢复后在等的回执照样拉得回来。断网时照常拉，拉成功就是恢复了（`SyncStatus.offline`）。
    func pollingCondition() -> AsyncStream<SyncPoller.Cadence?> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                // 依赖的状态变了节奏不一定变（如 Cue 在想与空闲之间来回）：同样的节奏不再给，免得拉取循环每次都从头立即拉
                var last: Polling?
                for await polling in Observations({ Polling(cadence: self.pollingCadence, since: self.speech.reachableSince) })
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

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// 最多等 `syncWaitLimit` 就返回，下拉刷新的圈、"立即同步"按钮不跟着网络一直转；没做完的在后台接着做。
    /// 再要立即同步的（启动时与回到前台的那一次常常叠在一起）等这一次，不另拉一遍。
    func syncNow() async {
        guard sync != nil else { return }
        await (syncing ?? beginSyncNow()).value
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
        let waiting = Task {
            for await _ in settled {}
            deadline.cancel()
            syncing = nil
        }
        syncing = waiting
        return waiting
    }

    static let syncWaitLimit = Duration.seconds(5)

    /// "同步中"只有这一个来源。上传不算：那是本机的改动在往外走。
    /// 按节奏的拉取与收到推送的拉取也不算：它们一拉就完，算上的话页头每几秒闪一次。
    var isCatchingUp: Bool { isSyncingNow || syncState.catchingUp }

    /// 换新 Mac、还没对完时为 false：这时库里没有 Cue 不等于哪台都没设过。
    var knowsSyncedFacts: Bool {
        switch syncState.status {
        case .unavailable, .noAccount, .accountRestricted: true
        default: syncState.reconciled
        }
    }

    /// 本机就是它时库里就是最新的，不用等（Mac）。
    func isCatchingUp(on host: String?) -> Bool {
        #if os(macOS)
        isCatchingUp && host != hostID
        #else
        isCatchingUp
        #endif
    }

    /// 只有要当场生效的请求（停止、改名、补对话）看它。说的话不看：写下就排着，恢复后自动发出。
    var reachesPiHost: Bool {
        #if os(iOS)
        speech.reachableSince != nil  // 演示 Mac 在本机库里接手时一直算通（`SpeechClock`）
        #else
        true
        #endif
    }

    #if os(iOS)
    var macAlert: SyncSummary? {
        syncState.status.reachesMac ? nil : SyncSummary(syncState.status)
    }
    #endif

    var isSyncBusy: Bool {
        if isSyncingNow { return true }
        switch syncState.status {
        case .starting, .syncing: return true
        default: return false
        }
    }

    /// 没登录、受限时按了什么都不会发生，所以不给；上一次立即同步还没返回时照给、只停用，一按一松不让一行出现又消失。
    var canSyncNow: Bool {
        guard sync != nil else { return false }
        switch syncState.status {
        case .needsDecision, .outdated, .noAccount, .accountRestricted: return false
        default: return true
        }
    }

    /// 这个附件文件在本机的位置：没有就现在从 iCloud 取（手机上大文件、按流量计费时不自动取，用到时走这里）；没有同步（隔离库）抛 `FileFetchFailure.notSyncing`。
    func fetchFile(_ key: String) async throws -> URL { try await sync.fetchFile(key) }

    func resolveConflict(copy id: UUID, keep choice: ConflictChoice) async throws {
        try await store.resolveConflict(copy: id, keep: choice)
    }
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

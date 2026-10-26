import CueStore
import CueSync
import Foundation

/// iCloud 同步的 App 层接入：启动同步、把状态与冲突交给界面、激活时立即同步。
extension AppServices {
    /// 同步与它启动前的状态。没有同步时状态是写明原因的 `.unavailable`，界面不会显示成已同步。
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

    /// 启动同步，并让 `syncStatus`、`syncIssues`、`conflicts` 跟随，直到任务取消。没有同步（隔离模式）什么都不做。
    /// 启动后的第一次拉走立即同步（`CloudSync.start` 自己不拉；拉取等得到同步开始）：算在 `isCatchingUp` 里，打开的页面知道手里的可能不是最新。
    func startSync() {
        guard let sync else { return }
        connectSync()
        follow {
            for await state in sync.stateUpdates { self.setSyncState(state) }
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

    /// 回到前台的唯一入口（Mac 的 App 激活、iOS 任一窗口回到前台；已经在做的不重开）：iOS 恢复按节奏的拉取、重连门铃，立即同步。
    func handleActivation() async {
        startPolling()
        relay?.resume()
        await syncNow()
    }

    /// 手里有正在等的东西时按节奏拉（`SyncPoller`；节奏见 `pollingCadence`）。
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

    /// 拉一次（返回时拉完）：立即同步、按节奏的拉取、收到推送（前台的通知、后台的静默推送）与门铃都经这里。
    /// 同一时刻只有一拉，在跑时再来的合成下一拉，同步开始前来的（冷启动时先到的推送）等它开始了再拉：都在 `CloudSync.syncNow`。
    /// 不碰立即同步的忙碌状态（`syncNow`）。不在调用方的线程上跑（`@concurrent`）：从主线程来的也当场离开，主线程忙时拉取不跟着晚。
    /// 失败（多半是离线、被限流）由同步层归类、定下次的时刻并按段记日志，这里不另记：下一次触发或等待结束会再拉，状态变化经同步状态反映。
    @concurrent func pull() async {
        try? await sync?.syncNow()
    }

    /// 此刻该按什么节奏拉（nil：不拉）。"是否在等"只在这里定义，节奏见 `SyncPoller.Cadence.mac`、`.phone`，门铃通着（`doorbellFallback`）时降为兜底：
    /// - Mac：桥上有连着的 Pi 会话（手机可能随时发来请求；以桥为准，资料库里的状态记录可能是没来得及标为结束的旧会话），
    ///   或有还没结果的投送请求（发给本机的，或本机发给别的 Mac 上会话的），或 Cue 在这台值班（你在手机上对它说的话、
    ///   "等你"的回答、别的 Mac 接管只经这一拉才到，会话都关着时它也在等）；Mac 不收推送（docs/sync.md「Agent 与 Cue 的通知」）；
    /// - 手机：有在等回执的话（发往 Mac 还没结果的请求、还没交给 Cue 的你的话，`hasOpenDeliveries`），或正在看 Agent 页、会话近况、
    ///   Cue 页（状态与对话是活的）。进入后台整体停掉（见 `stopPolling`）。
    var pollingCadence: SyncPoller.Cadence? {
        #if os(macOS)
        DebugHooks.pollsLikePhone
            ? .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: true, doorbell: doorbellFallback)
            : .mac(waiting: hasOpenDeliveries || !pi.slots.isEmpty || cue.onDuty, doorbell: doorbellFallback)
        #else
        .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: piViewers > 0 || cueViewers > 0, doorbell: doorbellFallback)
        #endif
    }

    /// `pollingCadence` 随它依赖的状态变化给出新值；本机同步恢复时（`Speech.Moment.reachableSince` 换了）也重给一次，
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

    /// iOS 进入后台：停掉按节奏的拉取（回前台由 `handleActivation` 再开）。
    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    /// 立即同步：立即拉一次（`pull`，与按节奏的拉取同一拉；待推送顺带发出去，不等），最多等 `syncWaitLimit` 就返回：下拉刷新的圈、"立即同步"按钮跟着它停，
    /// 不跟着网络一直转。没做完的在后台接着做，拉到的照常经资料库出现在界面上。期间 `isSyncingNow`，再要立即同步的
    /// （启动时与回到前台的那一次常常叠在一起）等这一次，不另拉一遍。
    func syncNow() async {
        guard sync != nil else { return }
        await (syncing ?? beginSyncNow()).value
    }

    /// 开始一次立即同步：拉取当场在主线程之外开始（不排在主线程的队列后面），返回的任务至多等 `syncWaitLimit`，结束时清掉 `syncing`。
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

    /// 本机的数据此刻可能不是最新——"同步中"只有这一个来源：正在和 iCloud 对一遍（启动、回到前台、下拉刷新、立即同步的那一拉还没回来，
    /// 至多 `syncWaitLimit`），或在一页页地拉积压（第一次同步、离线久了，`SyncState.catchingUp`）。上传不算：那是本机的改动在往外走。
    /// 按节奏的拉取与收到推送的拉取也不算：它们一拉就完，算上的话页头每几秒闪一次。
    var isCatchingUp: Bool { isSyncingNow || syncCatchingUp }

    /// 别的设备写下的事实（Cue 在哪台启用）本机库里已经有了：和 iCloud 对过至少一遍，或没有可对的（没有同步、没登录 iCloud、账号受限）。
    /// 换新 Mac、还没对完时为 false：这时库里没有 Cue 不等于哪台都没设过。
    var knowsSyncedFacts: Bool {
        switch syncStatus {
        case .unavailable, .noAccount, .accountRestricted: true
        default: syncReconciled
        }
    }

    /// 事实写在 `host` 上的这一页（Cue 运行的 Mac、会话所在的 Mac）此刻可能不是最新：本机就是它时库里就是最新的，不用等（Mac）。
    func isCatchingUp(on host: String?) -> Bool {
        #if os(macOS)
        isCatchingUp && host != hostID
        #else
        isCatchingUp
        #endif
    }

    /// 同步那一行转不转圈（Mac 设置与手机设置共用）：正在连接、正在上传或对账，或立即同步还没返回。
    var isSyncBusy: Bool {
        if isSyncingNow { return true }
        switch syncStatus {
        case .starting, .syncing: return true
        default: return false
        }
    }

    /// "立即同步"按钮（Mac 设置与手机设置共用）能不能按：有同步、没停下（等你决定、这台要更新）、上一次立即同步已经返回。
    var canSyncNow: Bool {
        guard sync != nil, !isSyncingNow else { return false }
        switch syncStatus {
        case .needsDecision, .outdated: return false
        default: return true
        }
    }

    /// 处理 `syncStatus == .needsDecision`：用户选择后同步重新开始。
    func resolveSync(_ resolution: SyncResolution) async throws {
        try await sync?.resolve(resolution)
    }

    func resolveConflict(copy id: UUID, keep choice: ConflictChoice) async throws {
        try await store.resolveConflict(copy: id, keep: choice)
    }
}

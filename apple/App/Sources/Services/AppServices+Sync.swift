import CueStore
import CueSync
import Foundation

/// iCloud 同步的 App 层接入：启动引擎、把状态与冲突交给界面、激活时立即同步。
extension AppServices {
    /// 引擎与它启动前的状态。没有引擎时状态是写明原因的 `.unavailable`，界面不会显示成已同步。
    static func makeSync(
        _ source: SyncSource, store: CueStore, location: LibraryLocation
    ) -> (engine: (any SyncControlling)?, status: SyncStatus) {
        let engine: Result<any SyncControlling, NoSync>
        switch source {
        case .iCloud: engine = makeSync(store: store, location: location)
        case .custom(let sync): engine = .success(sync)
        }
        switch engine {
        case .success(let sync): return (sync, .starting)
        case .failure(let reason):
            log.notice("同步未启用：\(reason.description, privacy: .public)")
            return (nil, .unavailable(reason.description))
        }
    }

    /// 不创建引擎的两种情况：隔离模式（`CUEPAD_LIBRARY_DIR`，开发与验收用，不能碰真实账号的云端数据）；
    /// 本机 ad-hoc 构建没有 iCloud 权限（CloudKit 缺权限时会直接抛 ObjC 异常使进程崩溃，只有签名构建才有）。
    static func makeSync(
        store: CueStore, location: LibraryLocation, hasCloudKitEntitlement: Bool = Entitlements.hasCloudKit
    ) -> Result<any SyncControlling, NoSync> {
        guard !location.isIsolated else { return .failure(.isolated) }
        guard hasCloudKitEntitlement else { return .failure(.noEntitlement) }
        return .success(CloudSync(store: store))
    }

    nonisolated enum NoSync: Error, CustomStringConvertible {
        case isolated, noEntitlement

        var description: String {
            switch self {
            case .isolated: "隔离模式（CUEPAD_LIBRARY_DIR）不连 iCloud"
            case .noEntitlement: "这个构建没有 iCloud 权限（本机开发构建），不会同步"
            }
        }
    }

    /// 启动引擎，并让 `syncStatus`、`syncIssues`、`conflicts` 跟随，直到任务取消。没有引擎（隔离模式）什么都不做。
    func startSync() {
        guard let sync else { return }
        tasks.append(Task {
            for await state in sync.stateUpdates { setSyncState(state) }
        })
        tasks.append(Task {
            do {
                try await sync.start()
            } catch {
                syncFailedToStart(error)
            }
        })
        tasks.append(Task {
            do {
                for try await conflicts in store.observe([.cards], { try $0.conflicts() }) { setConflicts(conflicts) }
            } catch {
                reportIssue(.syncUnavailable("冲突列表读取失败：\(error)"))
            }
        })
        #if os(macOS)
        startWakeSync()
        #endif
        startPolling()
    }

    /// 应用回到前台：立即同步（推送之外的兜底），iOS 恢复主动拉取。
    func handleActivation() async {
        startPolling()
        await syncNow()
    }

    /// 推送不保证送达，手里有正在等的东西时按节奏主动拉（`SyncPoller`；节奏见 `pollingCadence`，直接拉同步区变化见
    /// `CloudSync.pullChanges`）。已经在拉就不重开。
    func startPolling() {
        guard let sync, polling == nil else { return }
        let waiting = pollingCondition()
        let log = Self.log
        polling = Task {
            await SyncPoller().run(while: waiting) {
                do {
                    try await sync.pullChanges()
                } catch {
                    log.notice("主动拉取失败：\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// 此刻该按什么节奏主动拉（nil：不拉）。"是否在等"只在这里定义；等的对象所在的表见 `ZoneChangePuller.awaitedTables`，
    /// 加新的等待理由时一并更新：
    /// - Mac：桥上有连着的 Pi 会话（手机可能随时发来请求；以桥为准，资料库里的状态记录可能是没来得及标为结束的旧会话），
    ///   或有发给本机、还没结果的投送请求时，每 2 秒；
    /// - 手机：有发往 Mac 还没结果的请求时每 2 秒、每次在等最多 2 分钟；正在看 Agent 页或会话近况时每 3 秒（状态是活的，
    ///   不靠推送），离开即停；两者都有时每 2 秒、不限时。进入后台整体停掉（见 `stopPolling`）。
    var pollingCadence: SyncPoller.Cadence? {
        #if os(macOS)
        !pi.slots.isEmpty || hasOpenDeliveries ? SyncPoller.Cadence(interval: .seconds(2)) : nil
        #else
        switch (hasOpenDeliveries, piViewers > 0) {
        case (true, true): SyncPoller.Cadence(interval: .seconds(2))
        case (true, false): SyncPoller.Cadence(interval: .seconds(2), limit: .seconds(120))
        case (false, true): SyncPoller.Cadence(interval: .seconds(3))
        case (false, false): nil
        }
        #endif
    }

    /// `pollingCadence` 随它依赖的状态变化给出新值；期间跟着资料库更新 `hasOpenDeliveries`。
    func pollingCondition() -> AsyncStream<SyncPoller.Cadence?> {
        #if os(macOS)
        let host = hostID
        let deliveries = openDeliveries { $0.hostID == host }
        #else
        let deliveries = openDeliveries { _ in true }  // 手机的请求都发往某台 Mac
        #endif
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                let tracking = Task { for await open in deliveries { self.hasOpenDeliveries = open } }
                defer { tracking.cancel() }
                for await cadence in Observations({ self.pollingCadence }) { continuation.yield(cadence) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 有没有符合条件、还没结果的投送请求，请求表变化时重算；读失败时报告并结束（不再主动拉，推送与切前台照常）。
    private func openDeliveries(_ matches: @escaping @Sendable (DeliveryRequest) -> Bool) -> AsyncStream<Bool> {
        let changes = store.observe([.deliveryRequests]) { store in try store.deliveryRequests().contains { $0.isOpen && matches($0) } }
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                do {
                    for try await open in changes { continuation.yield(open) }
                } catch {
                    self?.reportIssue(.syncUnavailable("读取待处理的请求失败，不再主动拉取：\(error)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// iOS 进入后台：停掉主动拉取（回前台由 `handleActivation` 再开）。
    func stopPolling() {
        polling?.cancel()
        polling = nil
    }


    /// 立即拉取并推送。失败（多半是离线）只记日志：引擎自己会重试，状态变化会经 `syncStatus` 反映。
    func syncNow() async {
        guard let sync else { return }
        do {
            try await sync.syncNow()
        } catch {
            Self.log.notice("立即同步失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 处理 `syncStatus == .needsDecision`：用户选择后引擎重新开始。
    func resolveSync(_ resolution: SyncResolution) async throws {
        try await sync?.resolve(resolution)
    }

    /// 冲突副本：选定保留的版本，另一份删除。
    func resolveConflict(copy id: UUID, keep choice: ConflictChoice) async throws {
        try await store.resolveConflict(copy: id, keep: choice)
    }
}

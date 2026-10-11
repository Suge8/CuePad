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
        DeviceState.current.start()
        return .success(CloudSync(store: store, deviceState: { DeviceState.current.snapshot() }))
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
                for try await conflicts in store.observe { try $0.conflicts() } { setConflicts(conflicts) }
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
    ///   或有还没结果的投送请求（发给本机的，或本机发给别的 Mac 上会话的）时，每 2 秒。闲着时也是 2 秒：Mac 上会话一连几天，这是一小时 1800 次、一天四万多次，
    ///   但没有推送可靠性的数据前不拿延迟换请求数；数据看到达日志（`xc.sh synclat`），放慢的条件见 docs/sync.md「拉取节奏」；
    /// - 手机：有发往 Mac 还没结果的请求时每 2 秒、每次在等最多 2 分钟；正在看 Agent 页或会话近况时每 3 秒（状态是活的，
    ///   不靠推送），离开即停；两者都有时每 2 秒、不限时。进入后台整体停掉（见 `stopPolling`）。
    var pollingCadence: SyncPoller.Cadence? {
        #if os(macOS)
        .mac(hasOpenDeliveries: hasOpenDeliveries, hasSessions: !pi.slots.isEmpty)
        #else
        .phone(hasOpenDeliveries: hasOpenDeliveries, isViewingAgents: piViewers > 0)
        #endif
    }

    /// `pollingCadence` 随它依赖的状态变化给出新值；期间跟着资料库更新 `hasOpenDeliveries`。
    func pollingCondition() -> AsyncStream<SyncPoller.Cadence?> {
        let deliveries = openDeliveries()
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

    /// 有没有还没结果的投送请求，请求表变化时重算；读失败时报告并结束（不再主动拉，推送与切前台照常）。
    private func openDeliveries() -> AsyncStream<Bool> {
        let changes = store.observe { store in try store.deliveryRequests().contains { $0.isOpen } }
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

extension SyncPoller.Cadence {
    /// Mac 的节奏，规则见 `AppServices.pollingCadence`。
    static func mac(hasOpenDeliveries: Bool, hasSessions: Bool) -> Self? {
        hasOpenDeliveries || hasSessions ? Self(.every(.seconds(2))) : nil
    }

    /// 手机的节奏，规则见 `AppServices.pollingCadence`。
    static func phone(hasOpenDeliveries: Bool, isViewingAgents: Bool) -> Self? {
        switch (hasOpenDeliveries, isViewingAgents) {
        case (true, true): Self(.every(.seconds(2)))
        case (true, false): Self(.every(.seconds(2), for: .seconds(120)))
        case (false, true): Self(.every(.seconds(3)))
        case (false, false): nil
        }
    }
}

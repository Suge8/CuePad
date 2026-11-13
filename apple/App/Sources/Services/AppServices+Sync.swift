import CueStore
import CueSync
import Foundation

extension AppServices {
    /// `.iCloud` 不创建同步的两种情况：隔离模式（`CUEPAD_LIBRARY_DIR`，开发与验收用，不能碰真实账号的云端数据；
    /// 例外只有 Debug 构建的模拟云（`-CuePadSharedCloud`）与同步测量连开发环境（开发环境签名、`-CuePadCloudKit YES`），见 `DebugHooks.syncsIsolatedLibrary`）；
    /// 本机 ad-hoc 构建没有 iCloud 权限（CloudKit 缺权限时会直接抛 ObjC 异常使进程崩溃，只有签名构建才有）。
    static func makeSync(
        _ source: SyncSource, store: CueStore, location: LibraryLocation
    ) -> (engine: (any SyncControlling)?, status: SyncStatus) {
        let reason: String
        switch source {
        case .custom(let sync): return (sync, .starting)
        case .built(let make): return (make(store), .starting)
        case .iCloud where location.isIsolated && !DebugHooks.syncsIsolatedLibrary: reason = String(localized: "开发用的隔离资料库，不连 iCloud")
        case .iCloud where !Entitlements.hasCloudKit && DebugHooks.sharedCloud == nil: reason = String(localized: "这个构建没有 iCloud 权限（本机开发构建），不会同步")
        case .iCloud: return (DebugHooks.cloudSync(store), .starting)
        }
        log.notice("同步未启用：\(reason, privacy: .public)")
        return (nil, .unavailable(reason))
    }

    func startSync() {
        guard sync != nil else { return }
        syncing.startSync()
        #if os(macOS)
        startWakeSync()
        holdActivityWhilePolling()
        #endif
    }

    /// 回到前台的唯一入口；已经在做的不重开。
    func handleActivation() async {
        syncing.startPolling()
        relay?.resume()
        await sync?.activated()
        await syncing.syncNow()
    }

    /// nil：不拉。"是否在等"只在这里定义；门铃通着（`doorbellFallback`）时降为兜底。
    /// Mac 以桥上连着的会话为准，资料库里的状态记录可能是没来得及标为结束的旧会话；Mac 不收推送。
    var pollingCadence: SyncPoller.Cadence? {
        #if os(macOS)
        DebugHooks.pollsLikePhone
            ? .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: true, doorbell: doorbellFallback)
            : .mac(waiting: hasOpenDeliveries || !bridge.slots.isEmpty || cue.onDuty, doorbell: doorbellFallback)
        #else
        .phone(hasOpenDeliveries: hasOpenDeliveries, isWatching: !viewer.viewing.isEmpty, doorbell: doorbellFallback)
        #endif
    }

    /// 同步通断变了时要跟着做的、不归同步管的事。
    func syncStatusChanged(to new: SyncStatus) {
        #if os(macOS)
        if new == .outdated { updates.checkInBackground() }
        #else
        switch new {
        case .noAccount: cueActivity?.invalidate(reason: "syncNoAccount")
        case .needsDecision: cueActivity?.invalidate(reason: "syncNeedsDecision")
        default: break
        }
        #endif
    }
}

import CueStore
import CueSync
import Foundation

/// 同步测量（`SyncBench`，docs/perf.md「同步测量」）伸进产品代码的钩子；Release 里什么都不做。
extension DebugHooks {
    /// 页面的订阅拿到新值（`Observing`）：测量据此记一句话第一次画进页面的时刻。
    static func observed(_ value: some Sendable) {
        #if DEBUG && os(macOS)
        if SyncBench.role != nil { SyncBench.Watch.observed(value) }
        #endif
    }

    /// 不连门铃（`-CuePadSyncBenchNoRelay YES`）：量门铃不通时只靠按节奏拉的那条路，不停正式中转。
    static var relayOff: Bool {
        #if DEBUG && os(macOS)
        SyncBench.relayOff
        #else
        false
        #endif
    }

    /// 连 iCloud 的同步：测量的实例换成 `CloudOutage` 的那份（默认共用的模拟云，见 `SyncBench.cloud`），其余就是 `CloudSync(store:)`。
    static func cloudSync(_ store: CueStore) -> CloudSync {
        #if DEBUG && os(macOS)
        if SyncBench.role != nil {
            return CloudOutage.cloudSync(store: store, shared: SyncBench.sharedCloud, budget: SyncBench.budget)
        }
        #endif
        return CloudSync(store: store)
    }
}

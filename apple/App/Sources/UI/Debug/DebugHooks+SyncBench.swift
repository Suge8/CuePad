import CueStore
import CueSync
import Foundation

extension DebugHooks {
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

    /// 连 iCloud 的同步：给了 `-CuePadSharedCloud` 的实例换成 `CloudOutage` 里连模拟云的那份，测量实例没给时连 CloudKit 开发环境，其余就是 `CloudSync(store:)`。
    static func cloudSync(_ store: CueStore) -> CloudSync {
        #if DEBUG
        if let sharedCloud { return CloudOutage.cloudSync(store: store, shared: sharedCloud, budget: nil) }
        #endif
        #if DEBUG && os(macOS)
        if SyncBench.role != nil { return CloudOutage.cloudSync(store: store, shared: nil, budget: SyncBench.budget) }
        #endif
        return CloudSync(store: store)
    }
}

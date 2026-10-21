import CueStore
import Foundation

extension AppServices {
    /// 改 Cue 的设置（同步的 `CueProfile`）：两端的写入口——名字、停用、Agent、模型与思考强度；启用另走 `enableCue`（要按那台 Mac 判断）。
    /// 写库后马上传这一条，别的设备马上看到；Cue 运行的那台 Mac 的管理器读到就按新设置值班。
    func updateCue(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
        await upload(CueProfile.recordID)
    }

    /// 让 Cue 运行在 `host` 那台 Mac 并启用（规则 `CueStore.enableCue`）：两端所有入口都经这里，界面读的是同一处判断（`CueGate`）。
    /// 这台的库还没和 iCloud 对过一遍时拒绝（`CueEnableError.unsynced`）：库里没有 Cue 不等于哪台都没设过，启用了会把它从原来那台抢过来；
    /// 它正在别的 Mac 上运行时，只有 `moving`（你确认了改在这台运行）才改。是这台 Mac 时先重新探测一次本机的 Agent
    /// （刚启动还没探测完也不会按旧的或空的判断）；别的 Mac 按它同步来的那条。写完马上传。
    func enableCue(on host: String, moving: Bool) async throws {
        guard knowsSyncedFacts else { throw CueEnableError.unsynced }
        #if os(macOS)
        if host == hostID { try await macAgents.record() }
        #endif
        try await store.enableCue(on: host, moving: moving)
        await upload(CueProfile.recordID)
    }
}

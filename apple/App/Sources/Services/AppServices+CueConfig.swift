import CueStore

extension AppServices {
    /// 启用另走 `enableCue`（要按那台 Mac 判断）。
    func updateCue(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
    }

    /// 两端所有入口都经这里，界面读的是同一个事实（`CueGate`）。
    /// 这台的库还没和 iCloud 对过一遍时拒绝（`CueEnableError.unsynced`）：库里没有 Cue 不等于哪台都没设过，启用了会把它从原来那台抢过来；
    /// 它正在别的 Mac 上运行时，只有 `moving`（你确认了改在这台运行）才改。是这台 Mac 时先重新探测一次本机的 Agent
    /// （刚启动还没探测完也不会按旧的或空的判断）；别的 Mac 按它同步来的那条。
    func enableCue(on host: String, moving: Bool) async throws {
        guard syncing.knowsSyncedFacts else { throw CueEnableError.unsynced }
        #if os(macOS)
        if host == hostID { try await macAgents.record() }
        #endif
        try await store.enableCue(on: host, moving: moving)
    }

    /// 各处的开关同一个，也是唯一的停用入口。开的时候按此刻库里的读，不按界面上一次读到的。`here` 是这台 Mac（手机为 nil）。一台 Mac 都没有时开不了，各处的开关那时停用。
    func turnCue(_ on: Bool, here: String?) async throws {
        guard on else { return try await updateCue { $0.enabledAt = nil } }
        guard let host = try await CueSettings.read(from: store).resumeHost(here: here) else { throw CueEnableError.noMac }
        try await enableCue(on: host.id, moving: false)
    }

    var cueOnDutyHere: Bool {
        #if os(macOS)
        cue.onDuty
        #else
        false
        #endif
    }
}

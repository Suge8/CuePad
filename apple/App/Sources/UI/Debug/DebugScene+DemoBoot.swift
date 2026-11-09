#if DEBUG
import CueStore
import Foundation

/// 演示库里的会话与 Cue 此刻要被认作"此刻真在跑"（`CueStore.runtimeIsConfirmed`）：所属 Mac 在线，且报告与在线记录出自同一次开机。
/// 演示的两台 Mac（`demoHosts`）不是这台机器：模拟器上没有 `SystemBoot.id`，Mac 上的是这台自己的。所以演示写的在线记录、会话与 Cue 此刻
/// 都带同一个 `demoBoot`；在线记录只管 `MacPresence.lifetime`，起来时写一次、之后同真的那台（`MacPresenceKeeper`）每 `MacPresence.renewal` 续一次
/// （`keepDemoPresence`），不然开着过了期全成"状态未确认"。
extension DebugScene {
    nonisolated static let demoBoot = "demo-boot"
    nonisolated static let demoHosts = ["demo-mac", "demo-mini"]

    /// 这台 Mac 写的开机标识：演示的两台写 `demoBoot`，别的（这台 Mac 自己，cuerun）照真的。
    nonisolated static func boot(of host: String) -> String? { demoHosts.contains(host) ? demoBoot : SystemBoot.id }

    /// 演示 Mac 上会话状态的记录器（同真的那台的 `PiStateRecorder`，带演示的开机标识）。
    static func demoRecorder(_ store: CueStore, host: String = "demo-mac", minInterval: Duration = PiStateRecorder.detailInterval) -> PiStateRecorder {
        PiStateRecorder(store: store, hostID: host, minInterval: minInterval, bootID: boot(of: host))
    }

    /// 续演示 Mac 在线的那一个任务（一个进程一个）。
    private static var presenceKeeper: Task<Void, Never>?

    /// 写下两台演示 Mac 的在线记录，并起一个任务每 `MacPresence.renewal` 续一次（只起一个）。
    static func keepDemoPresence(_ store: CueStore) async throws {
        try await refreshDemoPresence(store)
        guard presenceKeeper == nil else { return }
        presenceKeeper = Task {
            while await Task.wait(for: MacPresence.renewal) {
                await running("续演示 Mac 的在线记录") { try await refreshDemoPresence(store) }
            }
        }
    }

    /// 两台演示 Mac 的在线记录写到此刻加 `MacPresence.lifetime`；`-CuePadCuePresence asleep` 时演示 Mac 记成此刻不在线（它在睡觉）。
    private static func refreshDemoPresence(_ store: CueStore) async throws {
        let asleep = args.cueOpts.presence == "asleep"
        for host in demoHosts {
            let awake = !(asleep && host == "demo-mac")
            try await store.recordMacPresence(host: host, bootID: demoBoot) { awake }
        }
    }
}

extension CueStore {
    /// 演示里写 Cue 此刻：记在 Cue 运行的那台 Mac 名下、带那台的开机标识（`DebugScene.boot(of:)`），同值班的管理器写下的一样，名牌与页头才认它。
    func setDemoCueState(
        _ state: PiWorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil
    ) throws {
        let host = try cueProfile()?.hostID
        try setCueState(state, detail: detail, step: step, round: round, context: context, hostID: host, bootID: host.flatMap(DebugScene.boot(of:)))
    }
}
#endif

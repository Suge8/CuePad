#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    nonisolated static let demoBoot = "demo-boot"
    nonisolated static let demoHosts = ["demo-mac", "demo-mini"]

    nonisolated static func boot(of host: String) -> String? { demoHosts.contains(host) ? demoBoot : SystemBoot.id }

    static func demoRecorder(_ store: CueStore, host: String = "demo-mac", minInterval: Duration = StateRecorder.detailInterval) -> StateRecorder {
        StateRecorder(store: store, hostID: host, minInterval: minInterval, bootID: boot(of: host))
    }

    private static var presenceKeeper: Task<Void, Never>?

    static func keepDemoPresence(_ store: CueStore) async throws {
        try await refreshDemoPresence(store)
        guard presenceKeeper == nil else { return }
        presenceKeeper = Task {
            while await Task.wait(for: MacPresence.renewal) {
                await running("续演示 Mac 的在线记录") { try await refreshDemoPresence(store) }
            }
        }
    }

    private static func refreshDemoPresence(_ store: CueStore) async throws {
        let asleep = args.cueOpts.presence == "asleep"
        for host in demoHosts {
            let awake = !(asleep && host == "demo-mac")
            try await store.recordMacPresence(host: host, bootID: demoBoot) { awake }
        }
    }
}

extension CueStore {
    func setDemoCueState(
        _ state: WorkState, detail: String? = nil, step: CueActivity.Touch? = nil, round: UUID? = nil, context: CueContext? = nil
    ) throws {
        let host = try cueProfile()?.hostID
        try setCueState(state, detail: detail, step: step, round: round, context: context, hostID: host, bootID: host.flatMap(DebugScene.boot(of:)))
    }
}
#endif

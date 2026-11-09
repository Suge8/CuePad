import CueStore
import Foundation

/// 在哪台启用、能不能启用的规则都在这里与 `CueGate`，界面（`CueSettingsModel`）只读结果。
nonisolated struct CueSettings: Equatable, Sendable {
    var profile: CueProfile
    var macs: [MacAgents]

    static let empty = CueSettings(profile: CueProfile(), macs: [])

    static func read(from store: isolated CueStore) throws -> CueSettings {
        CueSettings(profile: try store.cueProfile() ?? CueProfile(), macs: try store.allMacAgents())
    }

    var isOn: Bool { profile.activeHost != nil }

    struct Host: Identifiable, Equatable {
        let id: String
        let isHere: Bool
        let name: String
        let brains: [AgentKind]
        let whyNone: String

        var usable: Bool { !brains.isEmpty }
        /// 能不能选它启用：一家都用不了的别的 Mac 选不了（各入口列着、写为什么，是停用项）；这台照样能选——它的记录可能还没写下，
        /// 启用前会重新探测，Cue 页上点它还会打开接入面板给装法。
        var selectable: Bool { usable || isHere }
    }

    /// `here` 是这台 Mac（手机为 nil）时它排第一：这台刚启动、自己的记录还没写下时也在（启用前会先重新探测）。
    func hosts(here: String?) -> [Host] {
        var hosts = macs.map { mac in
            Host(id: mac.hostID, isHere: mac.hostID == here, name: mac.hostID == here ? Self.here : mac.shownName,
                 brains: mac.kinds, whyNone: mac.whyNone)
        }
        if let here {
            let local = hosts.firstIndex { $0.id == here }.map { hosts.remove(at: $0) }
            hosts.insert(local ?? Host(id: here, isHere: true, name: Self.here, brains: [], whyNone: ""), at: 0)
        }
        return hosts
    }

    /// 都不能用时仍给第一台，启用时说清为什么（`CueEnableError`）。一台都没有为 nil。
    func resumeHost(here: String?) -> Host? {
        let hosts = hosts(here: here)
        return hosts.first { $0.id == profile.hostID && $0.selectable } ?? hosts.first(where: \.selectable) ?? hosts.first
    }

    @MainActor func gate(_ services: AppServices) -> CueGate {
        let running = profile.activeHost
        return CueGate.of(services, running: running, name: running.map { id in macs.first { $0.hostID == id }?.shownName ?? MacAgents.unnamed })
    }

    private static var here: String { String(localized: "这台 Mac") }
}

/// 所有入口只读这一处；启用的入口（`AppServices.enableCue`）按同一个事实拒绝。
enum CueGate: Equatable {
    /// 入口写这句原因，不能启用。不通的原因只在同步那一组说（`SyncSummary`）
    case waiting(String)
    /// 改到别的 Mac 要你确认（`CueMove`）
    case runs(id: String, name: String)
    case open

    /// `running`：它此刻运行的那台（没启用为 nil），`name` 是那台的名字。
    static func of(_ services: AppServices, running: String?, name: String?) -> CueGate {
        guard services.knowsSyncedFacts else {
            return .waiting(services.syncState.status.reachesMac ? String(localized: "正在从 iCloud 同步…") : String(localized: "同步恢复后再启用"))
        }
        guard let running else { return .open }
        return .runs(id: running, name: name ?? MacAgents.unnamed)
    }

    var waitingReason: String? {
        if case .waiting(let why) = self { why } else { nil }
    }
}

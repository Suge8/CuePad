import CueStore
import Foundation

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
        var selectable: Bool { usable || isHere }
    }

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

enum CueGate: Equatable {
    case waiting(String)
    case runs(id: String, name: String)
    case open

    static func of(_ services: AppServices, running: String?, name: String?) -> CueGate {
        guard services.syncing.knowsSyncedFacts else {
            return .waiting(services.syncing.state.status.reachesMac ? String(localized: "正在从 iCloud 同步…") : String(localized: "同步恢复后再启用"))
        }
        guard let running else { return .open }
        return .runs(id: running, name: name ?? MacAgents.unnamed)
    }

    var waitingReason: String? {
        if case .waiting(let why) = self { why } else { nil }
    }
}

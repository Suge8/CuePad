import Foundation

extension AppServices {
    var cueReadiness: CueReadiness {
        if knowsSyncedFacts { return .ready }
        return .waiting(syncStatus.reachesMac ? String(localized: "正在从 iCloud 同步…") : String(localized: "同步恢复后再启用"))
    }
}

enum CueReadiness: Equatable {
    case ready
    case waiting(String)

    var waitingReason: String? {
        if case .waiting(let reason) = self { reason } else { nil }
    }
}

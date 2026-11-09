import CueStore
import Foundation

nonisolated struct PiRowFacts: Equatable {
    var note: Note?
    var subagents: PiSubagentSummary?
    var context: PiContextMeter?

    enum Note: Equatable {
        case ending, endFailed, renameFailed, renaming, draft
        case transit(String)

        var text: String {
            switch self {
            case .ending: String(localized: "正在结束…")
            case .endFailed: String(localized: "没能结束")
            case .renameFailed: String(localized: "没能改名")
            case .renaming: String(localized: "正在改名")
            case .draft: String(localized: "有草稿")
            case .transit(let text): text
            }
        }

        var isFailure: Bool { self == .endFailed || self == .renameFailed }
    }

    init(_ session: PiSessionState, shown: PiShown, end: Speech.Trip?, renaming: Bool, renameFailed: Bool, hasDraft: Bool) {
        note = if end?.inTransit == true { .ending }
            else if end?.failure != nil { .endFailed }
            else if renameFailed { .renameFailed }
            else if let transit = shown.note { .transit(transit) }
            else if renaming { .renaming }
            else if hasDraft { .draft }
            else { nil }
        guard session.state != .known(.ended) else { return }
        subagents = PiSubagentSummary(session.runtimeSubagents)
        context = session.context.flatMap(PiContextMeter.init).flatMap { $0.level == .roomy ? nil : $0 }
    }
}

extension AppSettings {
    func facts(_ session: PiSessionState, shown: PiShown, end: Speech.Trip?, rename: DeliveryRequest?, at moment: Speech.Moment) -> PiRowFacts {
        PiRowFacts(
            session, shown: shown, end: end, renaming: PiRename.isPending(rename, at: moment),
            renameFailed: PiRename.failed(rename, seen: sessionSeen[session.sessionID], at: moment), hasDraft: draftPreview(for: session.id) != nil)
    }
}


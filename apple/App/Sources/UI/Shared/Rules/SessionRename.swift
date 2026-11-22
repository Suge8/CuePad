import CueStore
import Foundation

nonisolated enum SessionRename {
    static func clean(_ name: String) -> String? {
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func title(of session: SessionState, request: DeliveryRequest?, at moment: Speech.Moment) -> String {
        guard let request, let name = request.config?.name else { return session.title }
        switch Speech.trip(request, at: moment) {
        case .sending, .sent: return name
        case .delivered: return session.modifiedAt > (request.completedAt ?? request.createdAt) ? session.title : name
        case .preparing, .failed, .unconfirmed: return session.title
        }
    }

    static func isPending(_ request: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        guard let request, request.isRename else { return false }
        return Speech.trip(request, at: moment).inTransit
    }

    static func failed(_ request: DeliveryRequest?, seen: Date?, at moment: Speech.Moment) -> Bool {
        guard let request, request.isRename, let failedAt = Speech.failedAt(request, at: moment) else { return false }
        return (seen ?? .distantPast) <= failedAt
    }
}

extension SessionListItem {
    func shownTitle(at moment: Speech.Moment) -> String { SessionRename.title(of: state, request: rename, at: moment) }

    func name(at moment: Speech.Moment) -> String { task?.title.nonEmpty ?? shownTitle(at: moment) }
}

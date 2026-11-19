#if os(macOS)
import CueStore
import SwiftUI

nonisolated struct SessionSearchData: Sendable, Equatable {
    var live: [SessionState]
    var ended: [SessionState]
    var endedTotal: Int
    var deliveries: [String: DeliveryRequest]
    var undelivered: [String: Int]

    static func read(text: String, project: UUID?, endedLimit: Int, at moment: Speech.Moment, from store: isolated CueStore) throws -> SessionSearchData {
        let live = try store.sessionPage(SessionQuery(scope: .live, text: text, project: project, limit: .max))
        let ended = try store.sessionPage(SessionQuery(scope: .ended, text: text, project: project, limit: endedLimit))
        return SessionSearchData(
            live: live.items.map(\.listed), ended: ended.items.map(\.listed), endedTotal: ended.total,
            deliveries: Dictionary((live.items + ended.items).compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first },
            undelivered: SessionListItem.undelivered(live.items + ended.items, at: moment))
    }
}

#endif

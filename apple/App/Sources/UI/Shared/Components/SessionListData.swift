import CueStore
import SwiftUI

nonisolated struct SessionListData: Sendable, Equatable {
    static let pageSize = 40

    struct Filter: Hashable, Sendable {
        var text: String
        var project: UUID?
    }

    struct Key: Equatable {
        var filter: Filter
        var limit: Int
        var moment: Speech.Moment
    }

    var filter: Filter
    var pinned: [SessionListItem]
    var now: [SessionListItem]
    var ended: [SessionListItem]
    var endedTotal: Int
    var ends: [UUID: Speech.Trip] = [:]

    var loaded: Int { ended.count }
    var hasMore: Bool { ended.count < endedTotal }
    var count: Int { pinned.count + now.count + endedTotal }
    var isEmpty: Bool { count == 0 }
    var showsPlace: Bool { filter.project == nil }

    static func read(
        text: String, project: UUID? = nil, historyLimit: Int, at moment: Speech.Moment, from store: isolated CueStore
    ) throws -> SessionListData {
        let pinned = try store.sessionPage(SessionQuery(scope: .all, text: text, project: project, pinned: true, limit: .max)).items
        let live = try store.sessionPage(SessionQuery(scope: .current, text: text, project: project, pinned: false, limit: .max)).items
            .filter { $0.isCurrent(at: moment) }
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let now = SessionState.inListOrder(live, state: \.state, deliveries: deliveries, cue: try store.cueDuty(), at: moment)
        let ended = try earlier(SessionQuery(text: text, project: project, pinned: false, limit: historyLimit), at: moment, from: store)
        return SessionListData(
            filter: Filter(text: text, project: project), pinned: pinned, now: now,
            ended: ended.items, endedTotal: ended.total,
            ends: try (pinned.filter { $0.state.state != .known(.ended) } + live).reduce(into: [:]) { ends, item in
                ends[item.id] = MacDelivery.endProgress(try store.deliveryRequests(toSession: item.state.sessionID), at: moment)
            })
    }

    static func earlier(_ query: SessionQuery, at moment: Speech.Moment, from store: isolated CueStore) throws -> SessionListPage {
        var query = query
        query.scope = .ended
        query.excluding = try store.sessionPage(.current).items
            .filter { $0.state.state == .known(.ended) && $0.isCurrent(at: moment) }.map(\.state.sessionID)
        return try store.sessionPage(query)
    }
}

extension SessionListData {
    var historyRuns: [TimeSection.Run<SessionListItem>] {
        TimeSection.split(ended, date: \.state.stateSince, now: .now)
    }
}

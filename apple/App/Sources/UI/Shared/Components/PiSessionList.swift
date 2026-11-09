import CueStore
import SwiftUI

/// `endedOnly`（"更早"那一页，`EarlierPage`）只读"历史"、置顶的也在里面，与会话条"更早"的个数同一个查询（`earlier`），没有置顶与"现在"两部分。
nonisolated struct PiSessionList: Sendable, Equatable {
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
    var pinned: [PiSessionListItem]
    var now: [PiSessionListItem]
    var ended: [PiSessionListItem]
    var endedTotal: Int
    var ends: [UUID: Speech.Trip] = [:]

    var loaded: Int { ended.count }
    var hasMore: Bool { ended.count < endedTotal }
    var count: Int { pinned.count + now.count + endedTotal }
    var isEmpty: Bool { count == 0 }
    var showsPlace: Bool { filter.project == nil }

    static func read(
        text: String, project: UUID? = nil, endedOnly: Bool = false, historyLimit: Int, at moment: Speech.Moment, from store: isolated CueStore
    ) throws -> PiSessionList {
        if endedOnly {
            let ended = try earlier(PiSessionQuery(text: text, project: project, limit: historyLimit), at: moment, from: store)
            return PiSessionList(filter: Filter(text: text, project: project), pinned: [], now: [], ended: ended.items, endedTotal: ended.total)
        }
        let pinned = try store.piSessionPage(PiSessionQuery(scope: .all, text: text, project: project, pinned: true, limit: .max)).items
        let live = try store.piSessionPage(PiSessionQuery(scope: .current, text: text, project: project, pinned: false, limit: .max)).items
            .filter { $0.isCurrent(at: moment) }
        let deliveries = Dictionary(live.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
        let now = PiSessionState.inListOrder(live, state: \.state, deliveries: deliveries, cue: try store.cueDuty(), at: moment)
        let ended = try earlier(PiSessionQuery(text: text, project: project, pinned: false, limit: historyLimit), at: moment, from: store)
        return PiSessionList(
            filter: Filter(text: text, project: project), pinned: pinned, now: now,
            ended: ended.items, endedTotal: ended.total,
            ends: try (pinned.filter { $0.state.state != .known(.ended) } + live).reduce(into: [:]) { ends, item in
                ends[item.id] = DeliveryRequest.shownEnd(in: try store.deliveryRequests(toSession: item.state.sessionID), at: moment)
            })
    }

    /// 正在唤醒的已在"现在"与会话条上（`PiSessionListItem.isCurrent`），唤醒按此刻算、库里认不出，读出来按会话 id 排掉，个数与分页才对得上。
    static func earlier(_ query: PiSessionQuery, at moment: Speech.Moment, from store: isolated CueStore) throws -> PiSessionPage {
        var query = query
        query.scope = .ended
        query.excluding = try store.piSessionPage(.current).items
            .filter { $0.state.state == .known(.ended) && $0.isCurrent(at: moment) }.map(\.state.sessionID)
        return try store.piSessionPage(query)
    }
}

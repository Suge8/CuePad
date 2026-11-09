import CueStore
import SwiftUI

/// 会话页读到的会话（Mac 与手机同一份）：一条列表，最上面是置顶的——绑在置顶任务上的（`PiSessionQuery.pinned`，在线的在前，结束了也留着；不多，不分页）；
/// 接着"现在"——其余在线的与正在唤醒的（`PiSessionListItem.isCurrent`；不多，不分页），按要你注意的先后；
/// "历史"在最下——其余已结束的（`earlier`：正在唤醒的在"现在"，不再列），按结束时间从新到旧分页读（分段见 `TimeSection`）。
/// 三部分用同一个搜索词与项目范围（`Workspace.projectScope`）。`endedOnly`（"更早"那一页，`EarlierPage`）只读"历史"、置顶的也在里面，
/// 与会话条"更早"的个数同一个查询（`earlier`），没有置顶与"现在"两部分。
nonisolated struct PiSessionList: Sendable, Equatable {
    static let pageSize = 40

    /// 搜索词与项目范围：两部分共用。
    struct Filter: Hashable, Sendable {
        var text: String
        var project: UUID?
    }

    /// 重读的条件：筛选、分页读到第几条，与此刻（到点、同步通断时次序与"没能送达"随之变，`AppServices.speech`）。
    struct Key: Equatable {
        var filter: Filter
        var limit: Int
        var moment: Speech.Moment
    }

    var filter: Filter
    var pinned: [PiSessionListItem]
    var now: [PiSessionListItem]
    /// 读到的历史（前 `limit` 条）与一共几条。
    var ended: [PiSessionListItem]
    var endedTotal: Int
    /// 在线会话此刻要显示的那次结束到哪了（按记录 id，`DeliveryRequest.shownEnd`）：正在结束、没能结束。会话页读同一条规则。
    var ends: [UUID: Speech.Trip] = [:]

    var loaded: Int { ended.count }
    var hasMore: Bool { ended.count < endedTotal }
    var count: Int { pinned.count + now.count + endedTotal }
    var isEmpty: Bool { count == 0 }
    /// 卡上写所在的项目图标：看全部项目时；只看一个项目时顶栏已经说了。
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

    /// "更早"（会话列表的"历史"、手机"更早"那一格与那一页、宽屏会话条的"更早"只读它）：已结束、此刻没在唤醒的。
    /// 正在唤醒的已在"现在"与会话条上（`PiSessionListItem.isCurrent`），唤醒按此刻算、库里认不出，读出来按会话 id 排掉，个数与分页才对得上。
    static func earlier(_ query: PiSessionQuery, at moment: Speech.Moment, from store: isolated CueStore) throws -> PiSessionPage {
        var query = query
        query.scope = .ended
        query.excluding = try store.piSessionPage(.current).items
            .filter { $0.state.state == .known(.ended) && $0.isCurrent(at: moment) }.map(\.state.sessionID)
        return try store.piSessionPage(query)
    }
}

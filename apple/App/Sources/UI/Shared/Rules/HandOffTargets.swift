import CueStore
import Foundation

/// 含托管着、进程歇着的（发话时 Mac 在后台唤醒）；已结束的不在其中（Mac 上刚结束的另列）。
enum HandOffTargets {
    /// 交给 Agent 的输入框读的去处（`CueStore.handOffPlan`）：默认交给 `bound`，没有时开新会话。
    /// 还没有哪台 Mac 写下过自己时没有决定（`noMac`）：新用户的常态、不是出错，原因叠在输入框上方。
    nonisolated struct Options: Equatable, Sendable {
        var plan: HandOffPlan?
        var bound: SessionListItem?
        var fresh: HandOffPlan?
        var opening: String?
        var noMac = false

        init(_ card: UUID?, in store: isolated CueStore) throws {
            guard let card else { return }
            let plan: HandOffPlan
            do {
                plan = try store.handOffPlan(card, host: nil)
            } catch CueStoreError.noMac {
                noMac = true
                return
            }
            self.plan = plan
            opening = try store.opening(of: plan.leaf, true)
            guard case .session(let id, _, _) = plan.destination else { fresh = plan; return }
            bound = try store.sessionItems(sessionIDs: [id])[id]
            fresh = try store.handOffPlan(card, host: nil, fresh: true)
        }
    }

    /// 绑着的会话排最前，在线的按与任务同项目、再按急不急排。
    static func sessions(_ live: [SessionListItem], project: UUID?, bound: SessionListItem? = nil, at moment: Speech.Moment) -> [SessionListItem] {
        func key(_ item: SessionListItem) -> (Int, Int) {
            (item.state.projectID == project && project != nil ? 1 : 0, SessionShown(item.state, delivery: item.delivery, at: moment).urgency)
        }
        let sorted = live.sorted { key($0) > key($1) }
        guard let bound, !sorted.contains(where: { $0.state.sessionID == bound.state.sessionID }) else { return sorted }
        return [bound] + sorted
    }

    static func title(_ item: SessionListItem, project: Project?, shown: SessionShown) -> Dotted {
        Dotted(item.state.title, item.state.agentMark, SessionPlace.name(of: item.state, project: project), shown.label)
    }
}

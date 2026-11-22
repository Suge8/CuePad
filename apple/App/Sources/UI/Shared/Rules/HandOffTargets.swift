import CueStore
import Foundation

enum HandOffTargets {
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

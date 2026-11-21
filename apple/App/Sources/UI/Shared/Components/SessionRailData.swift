import CueStore
import Foundation

nonisolated struct SessionRailData: Equatable, Sendable {
    struct Waiting: Equatable, Sendable {
        let agent: SessionListItem
        let deciding: Bool
        let cache: ChatMessage.Tools.Cache?
    }

    var waiting: [Waiting]
    var advancing: [SessionListItem]

    static func read(from store: isolated CueStore) throws -> Self {
        let tally = try store.cueTally()
        let asking = tally.waiting.compactMap { wait in
            if case .session(let session, _) = wait { session } else { nil }
        }.sorted { ($0.stateSince, $0.sessionID) < ($1.stateSince, $1.sessionID) }
        let waiting = asking + tally.replies.map(\.session)
        var seen = Set(waiting.map(\.sessionID))
        let advancing = tally.works.flatMap(\.sessions)
            .sorted { ($0.stateSince, $0.sessionID) > ($1.stateSince, $1.sessionID) }
            .filter { seen.insert($0.sessionID).inserted }
        let items = try store.sessionItems(sessionIDs: waiting.map(\.sessionID) + advancing.map(\.sessionID))
        let decisions = Set(asking.map(\.sessionID))
        let caches = try store.latestCaches(in: waiting.map(\.sessionID))
        return Self(
            waiting: waiting.map { Waiting(agent: items[$0.sessionID]!, deciding: decisions.contains($0.sessionID), cache: caches[$0.sessionID]) },
            advancing: advancing.map { items[$0.sessionID]! })
    }
}

struct SessionRailRows {
    struct Item: Identifiable {
        let session: SessionState
        let name: String
        let task: SessionTask?
        let pulse: BoardPulse
        let waiting: SessionShown.Status?
        var cache: ChatMessage.Tools.Cache?
        var id: String { session.sessionID }
    }

    let waiting: [Item]
    let advancing: [Item]

    init(_ data: SessionRailData, pulse: (SessionListItem) -> BoardPulse) {
        func item(_ value: SessionListItem, waiting: SessionShown.Status?, cache: ChatMessage.Tools.Cache? = nil) -> Item {
            let pulse = pulse(value)
            let session = pulse.session ?? value.state
            return Item(session: session, name: value.task?.title.nonEmpty ?? session.title, task: value.task, pulse: pulse, waiting: waiting, cache: cache)
        }
        waiting = data.waiting.map { item($0.agent, waiting: $0.deciding ? .asking : .awaitsReply, cache: $0.cache) }
        advancing = data.advancing.map { item($0, waiting: nil) }.enumerated().sorted {
            let left = $0.element.pulse, right = $1.element.pulse
            return (left.tier, left.shown?.rank ?? 0, $0.offset) < (right.tier, right.shown?.rank ?? 0, $1.offset)
        }.map(\.element)
    }
}

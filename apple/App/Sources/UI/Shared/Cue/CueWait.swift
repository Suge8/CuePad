import CueStore
import Foundation

nonisolated struct CueWait: Identifiable, Sendable, Equatable {
    var wait: CueTally.Wait
    var task: Card?
    var id: String { wait.id }
    var session: SessionState { wait.session }
    var title: String { task?.title ?? session.title }
    var since: Date { session.stateSince }
    var project: UUID? { task?.projectID ?? TaskBoard.home(session) }

    static func read(_ waiting: [CueTally.Wait], handed duty: CueDuty?, from store: isolated CueStore) throws -> [CueWait] {
        guard let duty else { return [] }
        return try waiting.filter { duty.tier(of: $0.session) != .yours }
            .map { CueWait(wait: $0, task: try $0.task.flatMap { try store.card($0) }) }
            .sorted { ($0.since, $0.id) < ($1.since, $1.id) }
    }
}

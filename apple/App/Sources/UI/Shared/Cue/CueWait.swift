import CueStore
import Foundation

nonisolated struct CueWait: Identifiable, Sendable, Equatable {
    var wait: CueTally.Wait
    var task: Card?
    var id: String { wait.id }

    var message: CueMessage? {
        if case .message(let message, _) = wait { message } else { nil }
    }

    var title: String? {
        if let task { return task.title }
        if case .session(let session, _) = wait { return session.title }
        return nil
    }

    var since: Date {
        switch wait {
        case .message(let message, _): message.createdAt
        case .session(let session, _): session.stateSince
        }
    }

    /// Cue 的一般提问是它问时的范围（`CueMessage.asked`），没给范围的不属于哪个项目。
    var project: UUID? {
        if let task { return task.projectID }
        switch wait {
        case .session(let session, _): return TaskBoard.home(session)
        case .message(let message, _): return message.asked?.project
        }
    }

    static func read(_ waiting: [CueTally.Wait], from store: isolated CueStore) throws -> [CueWait] {
        try waiting.map { wait in CueWait(wait: wait, task: try wait.task.flatMap { try store.card($0) }) }
            .enumerated().sorted { ($0.element.since, $0.offset) < ($1.element.since, $1.offset) }.map(\.element)
    }
}

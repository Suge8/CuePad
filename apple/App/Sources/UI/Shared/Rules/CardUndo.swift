import CueStore
import Foundation

typealias Undo = @MainActor () async throws -> Void

/// 怎么拨回去是 Store 层的规则（`CueStore.undo`，回执在改动的同一个事务里读到），界面只负责把它挂到提示上。
extension CueStore {
    func merging(_ idea: UUID, into task: UUID) async throws -> Undo {
        undoing(try mergeIdea(idea, into: task))
    }

    func spawning(_ idea: UUID) async throws -> (task: Card, undo: Undo) {
        let (task, change) = try createTask(fromIdea: idea)
        return (task, undoing(change))
    }

    func trashing(_ ids: [UUID]) async throws -> Undo {
        undoing(try trashCards(ids))
    }

    private nonisolated func undoing(_ change: CardChange?) -> Undo { undoing(change.map { [$0] } ?? []) }

    private nonisolated func undoing(_ changes: [CardChange]) -> Undo {
        guard !changes.isEmpty else { return {} }
        return { try await self.undo(changes) }
    }
}

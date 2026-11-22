import CueStore
import Foundation

typealias Undo = @MainActor () async throws -> Void

extension CueStore {
    func merging(_ idea: UUID, into task: UUID) async throws -> Undo {
        undoing(try mergeIdea(idea, into: task))
    }

    func spawning(_ idea: UUID) async throws -> (task: Card, undo: Undo) {
        let (task, change) = try createTask(fromIdea: idea)
        return (task, undoing(change))
    }

    func moving(_ id: UUID, to slot: CardSlot, after previous: UUID?) async throws -> Undo {
        let change = try moveCard(id, to: slot, after: previous)
        return { try await self.undo(change, of: id, stillAt: slot, after: previous) }
    }

    func pinning(_ id: UUID, _ pinned: Bool) async throws -> Undo {
        try updateCard(id) { $0.isPinned = pinned }
        return {
            guard try await self.card(id)?.isPinned == pinned else { throw CueStoreError.changedSinceUndo }
            try await self.updateCard(id) { $0.isPinned = !pinned }
        }
    }

    func completing(_ id: UUID, at moment: Speech.Moment) async throws -> (status: TaskStatus, undo: Undo?, unreached: [SessionState]) {
        let done = try card(id)?.completedAt != nil
        let (status, unreached) = try completeTask(id, sleepingAt: moment)
        guard !done, status == .done, let time = try card(id)?.completedAt else { return (status, nil, unreached) }
        return (status, { try await self.uncompleteTask(id, completedAt: time) }, unreached)
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

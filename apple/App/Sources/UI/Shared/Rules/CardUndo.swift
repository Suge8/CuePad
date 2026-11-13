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

    func moving(_ id: UUID, to slot: CardSlot, after previous: UUID?) async throws -> Undo {
        let change = try moveCard(id, to: slot, after: previous)
        return { try await self.undo(change, of: id, stillAt: slot, after: previous) }
    }

    /// 读与改在 actor 的同一段里。置顶只有开与关，认不出"还是那一次"：此刻不是那次改成的样子就不撤、报"已改过"，不装作撤了。
    func pinning(_ id: UUID, _ pinned: Bool) async throws -> Undo {
        try updateCard(id) { $0.isPinned = pinned }
        return {
            guard try await self.card(id)?.isPinned == pinned else { throw CueStoreError.changedSinceUndo }
            try await self.updateCard(id) { $0.isPinned = !pinned }
        }
    }

    /// 本来就做完了的没有可撤的。
    func completing(_ id: UUID) async throws -> (status: TaskStatus, ended: [DeliveryRequest], undo: Undo?) {
        let done = try card(id)?.completedAt != nil
        let (status, ended) = try completeTask(id)
        guard !done, status == .done, let time = try card(id)?.completedAt else { return (status, ended, nil) }
        return (status, ended, { try await self.uncompleteTask(id, completedAt: time) })
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

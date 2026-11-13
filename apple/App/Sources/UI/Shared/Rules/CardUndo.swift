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

    /// 读修改时刻与移动在 actor 的同一段里，中间插不进别的写入。
    func moving(_ id: UUID, to slot: CardSlot, after previous: UUID?) async throws -> Undo {
        let change = try moveCard(id, to: slot, after: previous)
        guard let time = try card(id)?.modifiedAt else { return {} }
        return { try await self.undo(change, of: id, unchangedSince: time) }
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

import CueStore
import Foundation

/// 拨回刚才那一下（提示里的"撤销"，Mac 上 ⌘Z 也能点它）。
typealias Undo = @MainActor () async throws -> Void

/// 会留下"撤销"的卡片改动：怎么拨回去是 Store 层的规则（`CueStore.undo`，回执在改动的同一个事务里读到），界面只负责把它挂到提示上。
extension CueStore {
    /// 设为任务 / 改回灵感（改回时下级提到它的位置）。
    func settingTodo(_ id: UUID, _ on: Bool) async throws -> Undo {
        undoing(try setTodo(id, on))
    }

    /// 删除一条灵感或任务（进回收站，下级提到它的位置，见 `trashCard`）；撤销时下级回到它下面。
    func trashing(_ ids: [UUID]) async throws -> Undo {
        undoing(try trashCards(ids))
    }

    private nonisolated func undoing(_ change: CardChange?) -> Undo { undoing(change.map { [$0] } ?? []) }

    private nonisolated func undoing(_ changes: [CardChange]) -> Undo {
        guard !changes.isEmpty else { return {} }
        return { try await self.undo(changes) }
    }
}

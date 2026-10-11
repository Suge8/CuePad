import CueStore
import Foundation

/// 拨回刚才那一下（提示里的"撤销"，Mac 上 ⌘Z 也能点它）。
typealias Undo = @MainActor () async throws -> Void

/// 会留下"撤销"的卡片改动：怎么拨回去是 Store 层的规则（`CueStore.undo`，回执在改动的同一个事务里读到），界面只负责把它挂到提示上。
extension CueStore {
    /// 设为任务 / 改回灵感（改回时下级提到它的位置）。多行的灵感设为任务时拆出的那条提示词，撤销时原样合回正文。
    func settingTodo(_ id: UUID, _ on: Bool) async throws -> Undo {
        undoing(try setTodo(id, on))
    }

    /// 删除一条灵感或任务（进回收站，下级提到它的位置，见 `trashCard`）；撤销时下级回到它下面。
    func trashing(_ id: UUID) async throws -> Undo {
        undoing(try trashCard(id))
    }

    /// 灵感挂到任务下成为提示词（挑一条或拖到任务上）；撤销把它放回原来所在的项目、原来的位置。
    func attaching(_ idea: UUID, _ move: TaskMove) async throws -> Undo {
        undoing(try moveCard(idea, to: move.slot, after: move.after))
    }

    private nonisolated func undoing(_ change: CardChange?) -> Undo {
        guard let change else { return {} }
        return { try await self.undo(change) }
    }
}

import CueStore
import Foundation

extension Workspace {
    /// 看板上放下一张卡（`TaskBoard.drop` 定会发生什么）。
    func drop(_ drop: TaskBoard.Drop) {
        switch drop {
        case .place(let id, let move?): self.move(id, to: move.slot, after: move.after)
        case .place(_, nil): break
        case .backToTodo(let id, let move): perform { try await $0.returnToTodo(id, to: move?.slot, after: move?.after) }
        case .start(let task): handOff(task)
        case .finish(let item): attempt { try await self.finish(item) }
        case .finishSession(let agent): attempt { try await self.finish(agent) }
        case .endSession(let session): sleep(session)
        }
    }

    /// 拖放没有圈上那一下停留可撤销，卡也已离开原位：答应了当场完成，要问时窗口居中问。
    func finish(_ item: TaskBoard.Item) async throws {
        let id = item.task.id
        try await confirmComplete(
            id, subtasks: item.steps, busy: next(for: item, shown: pulse(of: item.agent).shown)?.busySession, anchored: false
        ) { try await $0.complete(id) }
    }
}

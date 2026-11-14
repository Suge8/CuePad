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
        case .endSession(let session): sessionAsk = .end(session)
        }
    }

    /// 还有没做完的子任务、它的 Agent 在做或在等你时先问（同完成圈，`TaskCheck`），答应了当场完成：拖放没有圈上那一下停留可撤销。
    func finish(_ item: TaskBoard.Item) async throws {
        let id = item.task.id
        if let steps = item.steps, TaskCopy.hasOpen(steps) { return sessionAsk = .completeSteps(id, steps) }
        if let busy = next(for: item, shown: pulse(of: item.agent).shown)?.busySession { return sessionAsk = .complete(busy, task: id) }
        try await complete(id)
    }
}

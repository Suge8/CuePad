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

    /// 放下的卡要先答一句才办（完成、休眠前的确认，触屏上交给谁）：问着时卡停在松手的地方（`BoardMoves.asking`）。
    /// 答应了完成、正办着也算：框先收起、库后写完（触屏上隔着收起的那段动画），中间这一截卡不往回走。休眠不换列，答完就回原处，不用等。
    var asksAboutDrop: Bool {
        #if os(iOS)
        sessionAsk != nil || answering > 0 || outbox != nil
        #else
        sessionAsk != nil || answering > 0
        #endif
    }

    /// 答应了完成前的那一问，办它。
    func answer(_ work: @escaping @MainActor (Workspace) async throws -> Void) {
        answering += 1
        attempt {
            defer { self.answering -= 1 }
            try await work(self)
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

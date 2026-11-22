import CueStore
import Foundation

extension Workspace {
    func drop(_ drop: TaskBoard.Drop) {
        switch drop {
        case .place(let id, let move?): self.move(id, to: move.slot, after: move.after)
        case .place(_, nil): break
        case .backToTodo(let id, let move): perform { try await $0.returnToTodo(id, to: move?.slot, after: move?.after) }
        case .start(let task):
            #if os(macOS)
            let sent = handOff(task)
            answer { _ in await sent?.value }
            #else
            handOff(task)
            #endif
        case .finish(let item): answer { try await $0.finish(item) }
        case .finishSession(let agent): answer { try await $0.finish(agent) }
        case .endSession(let session): sleep(session)
        }
    }

    var asksAboutDrop: Bool {
        #if os(iOS)
        sessionAsk != nil || answering > 0 || outbox != nil
        #else
        sessionAsk != nil || answering > 0
        #endif
    }

    func declineDrop() { dropDeclines += 1 }

    func answer(_ work: @escaping @MainActor (Workspace) async throws -> Void) {
        answering += 1
        attempt {
            defer { self.answering -= 1 }
            try await work(self)
        }
    }

    func finish(_ item: TaskBoard.Item) async throws {
        let id = item.task.id
        try await confirmComplete(
            id, subtasks: item.steps, busy: next(for: item, shown: pulse(of: item.agent).shown)?.busySession, anchored: false
        ) { try await $0.complete(id) }
    }
}

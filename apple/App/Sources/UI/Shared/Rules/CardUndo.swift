import CueStore
import Foundation

/// 拨回刚才那一下（提示里的"撤销"，Mac 上 ⌘Z 也能点它）。
typealias Undo = @MainActor () async throws -> Void

/// 会留下"撤销"的卡片改动：怎么拨回去是 Store 层的规则，界面只负责把它挂到提示上。
extension CueStore {
    /// 设为任务 / 改回灵感（改回时下级提到它的位置）。多行的灵感设为任务时拆出的那条提示词，撤销时原样合回正文。
    func settingTodo(_ id: UUID, _ on: Bool) async throws -> Undo {
        let body = try await card(id)?.body
        let prompt = try await setTodo(id, on)
        return {
            if let prompt, let body {
                try await self.purgeCard(prompt.id)
                try await self.updateCard(id) { $0.body = body }
            }
            try await self.setTodo(id, !on)
        }
    }

    /// 删除一条灵感或任务（进回收站，下级提到它的位置，见 `trashCard`）；撤销时下级回到它下面。
    func trashing(_ id: UUID) async throws -> Undo {
        let children = try await children(of: id).map(\.id)
        try await trashCard(id)
        return {
            try await self.restoreCard(id)
            var previous: UUID?
            for child in children {
                try await self.moveCard(child, to: .under(id), after: previous)
                previous = child
            }
        }
    }

    /// 灵感挂到任务下成为提示词（挑一条或拖到任务上）；撤销把它放回原来所在的项目、原来的位置。
    func attaching(_ idea: UUID, _ move: TaskMove) async throws -> Undo {
        guard let card = try await card(idea) else { throw CueStoreError.notFound }
        let siblings = try await cards(in: card.projectID).map(\.id)
        let before = siblings.firstIndex(of: idea).flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        try await moveCard(idea, to: move.slot, after: move.after)
        return { try await self.moveCard(idea, to: .top(project: card.projectID), after: before) }
    }
}

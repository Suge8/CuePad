import CueStore
import CueText
import SwiftUI

/// 一条任务的下级：任务页一次读出，各块只画。提示词发给的会话在窗口那一份里（`AgentLinks`，环境 `cardAgents`）。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 提示词与步骤，同级手动顺序。
    var children: [Card]
    /// 能挑来作提示词的：本项目散放的灵感，最近改过的在前。
    var ideas: [Card]

    static let ideaLimit = 20

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        let task = try store.card(id)
        let ideas = try store.cards(in: task?.projectID).filter { !$0.isTask && !$0.isPinned }.sorted { $0.modifiedAt > $1.modifiedAt }
        return TaskDetail(children: try store.children(of: id), ideas: Array(ideas.prefix(ideaLimit)))
    }

    var prompts: [Card] { children.filter { !$0.isTask } }
    var subtasks: [Card] { children.filter(\.isTask) }

    /// 步骤完成了几个；没有步骤为 nil。完成圈与"步骤 n/m"按它画。
    var progress: TaskProgress? {
        let subtasks = subtasks
        return subtasks.isEmpty ? nil : TaskProgress(done: subtasks.filter { $0.status == .done }.count, total: subtasks.count)
    }

    /// 一页的焦点：第一条还没发的提示词，只有它的"发给 Agent"是靛青主钮，其余没发的退成墨色，一眼看出从哪条开始。
    func primaryPrompt(agents: AgentLinks) -> UUID? {
        prompts.first { PromptDelivery($0.id, agents: agents, now: .now, reaches: { _ in true }) == .unsent }?.id
    }
}

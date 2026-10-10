import CueStore
import CueText
import SwiftUI

/// 一条任务的下级与各自做完没有：任务页一次读出，各块只画。交给的会话在窗口那一份里（`AgentLinks`，环境 `cardAgents`）。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 提示词与子任务，同级手动顺序。
    var children: [Card]
    /// 下级各自做完没有（与 `children` 同序）：提示词已回复、子任务完成。完成圈按它分段。
    var marks: [ChildMark]
    /// 能挑来作提示词的：本项目散放的灵感，最近改过的在前。
    var ideas: [Card]

    static let ideaLimit = 20

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        let task = try store.card(id)
        let ideas = try store.cards(in: task?.projectID).filter { !$0.isTask && !$0.isPinned }.sorted { $0.modifiedAt > $1.modifiedAt }
        return TaskDetail(
            children: try store.children(of: id), marks: try store.childMarks(of: id)[id] ?? [], ideas: Array(ideas.prefix(ideaLimit)))
    }

    var prompts: [Card] { children.filter { !$0.isTask } }
    var subtasks: [Card] { children.filter(\.isTask) }

    /// 一页的焦点：第一条还没交出去的提示词，只有它的"交给 Agent"是靛青主钮，其余没发的退成墨色，一眼看出从哪条开始。
    func primaryPrompt(agents: AgentLinks) -> UUID? { prompts.first { state(of: $0, agents: agents) == .unsent }?.id }

    /// 提示词此刻怎样；`agents` 是它交给的会话（含手机发出还没执行的、正在开的新会话）。
    func state(of prompt: Card, agents: AgentLinks) -> PromptState {
        let replied = zip(children, marks).first { $0.0.id == prompt.id }?.1.isDone ?? false
        return PromptState(isReplied: replied, handoff: agents.items[prompt.id], launching: agents.launching.contains(prompt.id))
    }
}

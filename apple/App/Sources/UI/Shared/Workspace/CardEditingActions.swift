import CueEditor
import CueStore
import CueText
import Foundation

extension CueSelectionAction {
    /// 编辑器选区的"转为任务"（Mac 的右键菜单、手机的编辑菜单同一项）：选中的字转成这张卡所在项目的任务。
    static func convertToTasks(from card: Card, workspace: Workspace) -> CueSelectionAction {
        CueSelectionAction(title: String(localized: "转为任务"), icon: .task) { stored in workspace.convertToTasks(stored, in: card.projectID) }
    }
}

extension Workspace {
    /// 变量取值存在卡片上；与卡上现有的一样时不写。
    func saveVariables(_ values: [String: String], of card: Card) {
        let id = card.id
        guard values != card.variableValues else { return }
        perform { try await $0.updateCard(id) { $0.variableValues = values } }
    }

    /// 编辑器里选中的文字转为任务并说一句结果：每行一个（规则见 `CueLines.taskLines`），归 `project`。
    /// 任务列表新的在上，倒着建，列表里的先后才与原文一致。
    func convertToTasks(_ stored: String, in project: UUID) {
        let lines = CueLines.taskLines(stored), store = services.store
        attempt {
            for line in lines.reversed() { _ = try await store.createTask(line, in: project) }
            self.say(lines.isEmpty ? "选中的部分没有文字" : "已转为 \(lines.count) 个任务", tone: lines.isEmpty ? .failure : .done)
        }
    }
}

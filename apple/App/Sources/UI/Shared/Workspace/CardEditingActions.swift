import CueEditor
import CueStore

extension CueSelectionAction {
    /// 编辑器选区的"转为任务"（Mac 的右键菜单、手机的编辑菜单同一项）：选中的字转成这张卡所在项目的任务。
    static func convertToTasks(from card: Card, workspace: Workspace) -> CueSelectionAction {
        CueSelectionAction(title: "转为任务", icon: .task) { stored in workspace.convertToTasks(stored, in: card.projectID) }
    }
}

extension Workspace {
    /// 变量取值存在卡片上；与卡上现有的一样时不写。
    func saveVariables(_ values: [String: String], of card: Card) {
        let id = card.id
        guard values != card.variableValues else { return }
        perform { try await $0.updateCard(id) { $0.variableValues = values } }
    }
}

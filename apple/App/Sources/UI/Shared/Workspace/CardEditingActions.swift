import CueEditor
import CueStore
import CueText
import Foundation

extension CueSelectionAction {
    static func convertToTasks(from card: Card, workspace: Workspace) -> CueSelectionAction {
        CueSelectionAction(title: String(localized: "转为任务"), icon: .task) { stored in workspace.convertToTasks(stored, in: card.projectID) }
    }
}

extension Workspace {
    func saveVariables(_ values: [String: String], of card: Card) {
        let id = card.id
        guard values != card.variableValues else { return }
        perform { try await $0.updateCard(id) { $0.variableValues = values } }
    }

    /// 任务列表新的在上，倒着建，列表里的先后才与原文一致。
    func convertToTasks(_ stored: String, in project: UUID) {
        let lines = CueLines.taskLines(stored), store = services.store
        attempt {
            for line in lines.reversed() { _ = try await store.createTask(line, in: project) }
            self.say(lines.isEmpty ? "选中的部分没有文字" : "已转为 \(lines.count) 个任务", tone: lines.isEmpty ? .failure : .done)
        }
    }
}

import CueStore
import CueText
import Foundation

extension Workspace {
    /// 编辑器里选中的文字转为任务：每行一个（规则见 `CueLines.taskLines`），归 `project`；返回建了几个。
    /// 任务列表新的在上，倒着建，列表里的先后才与原文一致。
    func addTasks(fromSelection stored: String, in project: UUID?) async throws -> Int {
        let lines = CueLines.taskLines(stored)
        for line in lines.reversed() { _ = try await services.store.createTask(line, in: project) }
        return lines.count
    }

    /// 转为任务并说一句结果（编辑器的选区动作用）。
    func convertToTasks(_ stored: String, in project: UUID?) {
        attempt {
            let count = try await self.addTasks(fromSelection: stored, in: project)
            self.say(count == 0 ? "选中的部分没有文字" : "已转为 \(count) 个任务", isError: count == 0)
        }
    }
}

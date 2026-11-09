import CueStore
import Foundation

/// 有效项目按 `store.projects()` 的顺序，界面不再另排（侧栏、书架、⌘1–9 与所有项目选择器都按它）。
/// 名称、图标、计数、目录都从这里同步取：进入项目页、打开菜单时第一帧就是真实值，不先显示默认值再替换。
nonisolated struct ProjectCatalog: Equatable, Sendable {
    var projects: [Project]
    var summaries: [UUID: ProjectSummary]
    /// 给用户看的任务数只读这里。
    var taskCounts: [UUID: TaskCounts]
    var directories: [UUID: String]
    var bindings: [DirectoryBinding]
    /// 一台 Mac 都没有为 nil。
    var workMac: MacAgents?

    var openTasks: [UUID: Int] { taskCounts.mapValues(\.open) }

    func project(_ id: UUID?) -> Project? {
        id.flatMap { id in projects.first { $0.id == id } }
    }

    static func read(from store: isolated CueStore) throws -> ProjectCatalog {
        let summaries = try store.projectSummaries()
        return ProjectCatalog(
            projects: try store.projects(),
            summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0) }),
            taskCounts: try store.taskCounts(),
            directories: try store.projectDirectories(),
            bindings: try store.directoryBindings(),
            workMac: try store.workMac().map(store.macAgents(on:)))
    }
}

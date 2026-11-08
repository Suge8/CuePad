import CueStore
import Foundation

/// 本窗口的项目目录：有效项目（`store.projects()` 的顺序，界面不再另排；侧栏、书架、⌘1–9 与所有项目选择器都按它）、各项目的灵感数、最近修改时间与未完成任务数、本机绑定的代码目录。
/// 由 `Workspace.follow` 订阅；项目的名称、图标、计数、目录在界面里都从这里同步取，
/// 进入项目页、打开菜单时第一帧就是真实值，不先显示默认值再替换。
nonisolated struct ProjectCatalog: Equatable, Sendable {
    var projects: [Project]
    var summaries: [UUID: ProjectSummary]
    /// 各项目的顶层任务数（`CueStore.taskCounts`，没有任务的不在里面）。给用户看的任务数只读这里。
    var taskCounts: [UUID: TaskCounts]
    var directories: [UUID: String]
    /// 各台 Mac 上的目录绑定（同步记录，本机的也在里面）：手机据此知道项目绑在哪台 Mac 的哪个文件夹，项目菜单与新会话落点都读它。
    var bindings: [DirectoryBinding]
    /// 没绑文件夹的项目在手机上交给哪台 Mac（`CueStore.workMac`）与它的名字：手机项目页写"在 <Mac> 上"、新会话据此发去；一台 Mac 都没有为 nil。
    var workMac: MacAgents?

    var openTasks: [UUID: Int] { taskCounts.mapValues(\.open) }

    /// 会话归的项目可以没有（`PiSessionState.projectID`），所以收可选的 id。
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

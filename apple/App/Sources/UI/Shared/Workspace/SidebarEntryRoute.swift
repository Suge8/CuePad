extension SidebarOutline.Entry {
    var route: Route {
        switch self {
        case .tasks: .tasks
        case .sessions: .agent
        case .allProjects: .shelf
        case .archive: .archive
        case .trash: .trash
        case .settings: .settings
        }
    }

    /// 行尾的计数：任务是没做完的，会话是在线的（"在做"列的，`Workspace.liveWork`）；其余没有。
    func count(in workspace: Workspace) -> Int {
        switch self {
        case .tasks: workspace.catalog?.allTasks.open ?? 0
        case .sessions: workspace.liveWork.rows.count
        default: 0
        }
    }
}

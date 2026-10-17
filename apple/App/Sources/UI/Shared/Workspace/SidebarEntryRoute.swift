extension SidebarOutline.Entry {
    /// 点这一行去的页（Mac 上"任务"开合任务面板，不去这一页）。
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

    /// 行尾的计数：任务是没做完的，会话是在线的；其余没有。
    func count(in workspace: Workspace) -> Int {
        switch self {
        case .tasks: workspace.catalog?.allTasks.open ?? 0
        case .sessions: workspace.services.liveSessions.total
        default: 0
        }
    }
}

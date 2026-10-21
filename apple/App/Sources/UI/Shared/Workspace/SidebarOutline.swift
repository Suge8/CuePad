import CueStore

/// 三端侧栏的结构只有这一份：有哪些条目、什么顺序、怎么分组、叫什么、用什么图标。Mac 的侧栏（`Sidebar`：去处是名片下面的两块磁贴）与 iPad 的列表
/// （`SplitSidebar`）只管长相与点了做什么；iPhone 底部那一排（`Dock`）取其中的去处。
/// 从上到下：Cue；去处（任务、会话）；项目（置顶的在前，其余按最近）；底部归档、回收站、设置。
/// 搜索不占一行：iPad 在列表顶上一个搜索框，iPhone 在三页顶上一颗搜索钮，Mac 在工具栏（⌘K）。
/// iPad 的列表只列置顶与最近的几个项目，项目区末尾一行"全部项目"进书架；Mac 没有书架，侧栏列出全部项目、项目区自己滚动。
nonisolated struct SidebarOutline: Equatable {
    /// 侧栏里固定的条目（Cue 与项目行之外的）。
    enum Entry {
        case tasks, sessions, allProjects, archive, trash, settings

        var title: String {
            switch self {
            case .tasks: "任务"
            case .sessions: "会话"
            case .allProjects: "全部项目"
            case .archive: "归档"
            case .trash: "回收站"
            case .settings: "设置"
            }
        }

        var icon: Icon {
            switch self {
            case .tasks: .task
            case .sessions: .session
            case .allProjects: .allProjects
            case .archive: .archive
            case .trash: .trash
            case .settings: .settings
            }
        }
    }

    static let places: [Entry] = [.tasks, .sessions]
    static let footer: [Entry] = [.archive, .trash, .settings]

    #if os(macOS)
    private static let recentLimit = Int.max
    #else
    /// 列表里最近的项目最多列几个：多了列表就不再是一眼看完的首页。
    private static let recentLimit = 5
    #endif

    let pinned: [Project]
    let recent: [Project]
    /// 项目区末尾有没有"全部项目"：手机与 iPad 一直有，Mac 没有。
    static let showsAllProjects = recentLimit != .max

    init(_ catalog: ProjectCatalog) {
        pinned = catalog.projects.filter(\.isPinned)
        recent = Array(catalog.projects.filter { !$0.isPinned }.prefix(Self.recentLimit))
    }

    var projects: [Project] { pinned + recent }
}

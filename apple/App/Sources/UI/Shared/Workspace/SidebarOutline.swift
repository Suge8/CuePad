import CueStore

/// 三端侧栏的结构只有这一份：有哪些条目、什么顺序、怎么分组、叫什么、用什么图标。Mac 的侧栏（`Sidebar`）与 iPhone、iPad 的列表
/// （`SplitSidebar`，iPhone 上它是导航栈的根、就是首页）只管长相与点了做什么。
/// 从上到下：Cue；去处（任务、会话）；项目（置顶的在前，其余按最近，再是未分类）；底部归档、回收站、设置。
/// 搜索不占一行：手机与 iPad 在列表顶上一个搜索框，Mac 在工具栏（⌘K）。
/// 手机与 iPad 的列表只列置顶与最近的几个项目，项目区末尾一行"全部项目"进书架；Mac 没有书架，侧栏列出全部项目、项目区自己滚动。
nonisolated struct SidebarOutline: Equatable {
    /// 侧栏里固定的条目（Cue 与项目行之外的）。
    enum Entry: CaseIterable {
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

        var symbol: String {
            switch self {
            case .tasks: "checklist"
            case .sessions: "waveform.path.ecg"
            case .allProjects: "square.grid.2x2"
            case .archive: "archivebox"
            case .trash: "trash"
            case .settings: "gearshape"
            }
        }
    }

    /// Cue 下面的去处。
    static let places: [Entry] = [.tasks, .sessions]
    /// 底部。
    static let footer: [Entry] = [.archive, .trash, .settings]

    #if os(macOS)
    private static let recentLimit = Int.max
    #else
    /// 列表里最近的项目最多列几个：多了列表就不再是一眼看完的首页。
    private static let recentLimit = 5
    #endif

    let pinned: [Project]
    let recent: [Project]
    /// 未分类的条数：有才列出那一行。
    let unfiled: Int
    /// 项目区末尾有没有"全部项目"（Mac 没有）。
    let showsAllProjects: Bool

    init(_ catalog: ProjectCatalog) {
        pinned = catalog.projects.filter(\.isPinned)
        recent = Array(catalog.projects.filter { !$0.isPinned }.prefix(Self.recentLimit))
        unfiled = catalog.unfiledCount
        showsAllProjects = Self.recentLimit != .max && !catalog.projects.isEmpty
    }

    /// 列出的项目，按显示顺序。
    var projects: [Project] { pinned + recent }
}

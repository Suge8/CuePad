import CueStore

/// 三端侧栏的结构只有这一份：有哪些条目、什么顺序、叫什么、用什么图标。Mac 的侧栏（`Sidebar`）与 iPad 的列表（`SplitSidebar`）只管长相与点了做什么；
/// iPhone 底部那一排（`Dock`）取其中的去处。
/// 从上到下：Cue；进展（看板｜会话，`Route.progress`）；项目（全部，置顶的在前，其余按最近）；底部归档、回收站、设置。
/// 项目行只有图标与名字：项目里在发生什么在项目页，要你拍板的在 Cue，在动的在进展。
/// 搜索不占一行：iPad 在列表顶上一个搜索框，iPhone 在项目页顶上中间一条搜索框、进展页左上一颗搜索钮，Mac 在工具栏（⌘K）。
nonisolated struct SidebarOutline: Equatable {
    /// 侧栏里固定的条目（Cue 与项目行之外的）。`projects` 只给 iPhone 底部那一排（窄屏的项目书架），侧栏的项目是一行一个项目。
    enum Entry {
        case progress, projects, archive, trash, settings

        var title: String {
            switch self {
            case .progress: String(localized: "进展")
            case .projects: String(localized: "项目")
            case .archive: String(localized: "归档")
            case .trash: String(localized: "回收站")
            case .settings: String(localized: "设置")
            }
        }

        var icon: Icon {
            switch self {
            case .progress: .task
            case .projects: .projects
            case .archive: .archive
            case .trash: .trash
            case .settings: .settings
            }
        }

        var route: Route {
            switch self {
            case .progress: .progress
            case .projects: .shelf
            case .archive: .archive
            case .trash: .trash
            case .settings: .settings
            }
        }
    }

    static let places: [Entry] = [.progress]
    static let footer: [Entry] = [.archive, .trash, .settings]

    /// 全部项目：置顶的在前，其余按项目目录的先后（最近）。
    let projects: [Project]

    init(_ catalog: ProjectCatalog) {
        projects = catalog.projects.filter(\.isPinned) + catalog.projects.filter { !$0.isPinned }
    }
}

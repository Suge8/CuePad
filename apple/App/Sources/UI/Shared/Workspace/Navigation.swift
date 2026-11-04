/// 项目｜进展的持久选择；看板｜会话仍由 `ProgressPane` 管。
enum NavigationPane: String, CaseIterable {
    case projects, progress
}

/// 窄屏只有以 Cue 为根的一个栈；Cue 不写进 path。侧栏盖在根 Cue 上，推入页盖住二者，不是另一个栈。
struct NarrowNavigation {
    var path: [Route] = []
    var sidebarOpen = false
}

/// 宽屏只有主区的去处：浏览落点（从偏好推出）、辅助页、一个会话，或并排两个会话（⌘ 点开的第二个在右半边，`beside`）。
/// 右边一直是 Cue，不进导航：它收没收起是用户的选择（`AppSettings.cueOpen`），放不下时浮出是这一刻的呈现（`Workspace.cueFloats`）。
/// 同一个会话最多在一边，回复草稿仍按会话 id 由 AppSettings 持有。
struct WideNavigation {
    enum Main {
        /// 浏览去处直接引用持久选择，不再复制项目 id 与分段。
        case browse
        case session(SessionRoute)
        case page(Route)

        init(_ route: Route) {
            switch route {
            case .shelf, .progress, .project, .cue: self = .browse
            case .session(let session): self = .session(session)
            default: self = .page(route)
            }
        }
    }

    var main: Main = .browse {
        didSet { if case .session = main {} else { beside = nil } }
    }
    /// 并排时右半边的会话；主区不是会话时没有（`main` 换走会话时一并清掉）。
    var beside: SessionRoute?
}

extension Workspace {
    enum Layout { case narrow, wide }
    /// 主区里一个会话占的那一边：`main` 是左半（只开一个时就是整个主区），`beside` 是并排时的右半。
    enum Column { case main, beside }
    enum Navigation {
        case narrow(NarrowNavigation)
        case wide(WideNavigation)
    }

    var layout: Layout {
        switch navigation {
        case .narrow: .narrow
        case .wide: .wide
        }
    }

    /// 单栈的路径绑定；宽屏没有导航历史。尺寸切换时旧视图的绑定写回不改新布局。
    var path: [Route] {
        get { if case .narrow(let state) = navigation { state.path } else { [] } }
        set {
            guard case .narrow(var state) = navigation else { return }
            state.path = newValue
            navigation = .narrow(state)
        }
    }

    var sidebarOpen: Bool {
        get {
            switch navigation {
            case .narrow(let state): state.sidebarOpen
            case .wide: railExpanded
            }
        }
        set {
            switch navigation {
            case .narrow(var state):
                state.sidebarOpen = newValue
                navigation = .narrow(state)
            case .wide: railExpanded = newValue
            }
        }
    }

    func toggleSidebar() {
        sidebarOpen.toggle()
    }

    /// 主区当前去处；窄屏指栈顶或根侧栏，侧栏内容读 sidebarRoute。
    var mainRoute: Route {
        switch navigation {
        case .narrow(let state): state.path.last ?? (state.sidebarOpen ? sidebarRoute : .cue)
        case .wide(let state):
            switch state.main {
            case .browse: browseRoute
            case .session(let session): .session(session)
            case .page(let route): route
            }
        }
    }

    var besideSession: SessionRoute? {
        if case .wide(let state) = navigation { state.beside } else { nil }
    }

    var navigationPane: NavigationPane { services.settings.navigationPane }
    var sidebarRoute: Route { navigationPane == .projects ? .shelf : .progress }
    var browseRoute: Route { Self.browseRoute(services.settings) }

    static func browseRoute(_ settings: AppSettings) -> Route {
        switch settings.navigationPane {
        case .projects: settings.currentProject.map(Route.project) ?? .shelf
        case .progress: .progress
        }
    }

    /// 选项目｜进展：窄屏保持侧栏展开，宽屏替换主区；会话、Cue 不改这个选择。
    func selectPane(_ pane: NavigationPane) {
        openTask = nil
        services.settings.navigationPane = pane
        switch layout {
        case .narrow: navigation = .narrow(NarrowNavigation(sidebarOpen: true))
        case .wide: selectWide(browseRoute)
        }
    }

    func remember(_ route: Route) {
        switch route {
        case .project(let id):
            services.settings.navigationPane = .projects
            services.settings.currentProject = id
        case .shelf:
            services.settings.navigationPane = .projects
            services.settings.currentProject = nil
        case .progress: services.settings.navigationPane = .progress
        default: break
        }
    }

    /// 宽→窄：浏览入口在侧栏，主区详情先入栈，并排的第二个会话在最上。
    /// 窄→宽：栈顶或浏览落点进主区（会话独占主区，其下的页回到浏览落点）。
    /// 只转换此刻的导航，不缓存旧布局。
    func setLayout(_ next: Layout) {
        guard next != layout else { return }
        switch navigation {
        case .wide(let state):
            var narrow: NarrowNavigation
            switch mainRoute {
            case .shelf, .progress: narrow = NarrowNavigation(sidebarOpen: true)
            case .project: narrow = NarrowNavigation(path: [mainRoute], sidebarOpen: true)
            default: narrow = NarrowNavigation(path: [mainRoute])
            }
            if let session = state.beside { narrow.path.append(.session(session)) }
            navigation = .narrow(narrow)
        case .narrow(let state):
            var wide = WideNavigation()
            if let page = state.path.last { wide.main = WideNavigation.Main(page) }
            navigation = .wide(wide)
        }
    }
}

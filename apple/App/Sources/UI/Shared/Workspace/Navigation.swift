/// 项目｜进展的持久选择；看板｜会话仍由 `ProgressPane` 管。
enum NavigationPane: String, CaseIterable {
    case projects, progress
}

/// 窄屏只有以 Cue 为根的一个栈；Cue 不写进 path。侧栏盖在根 Cue 上，推入页盖住二者，不是另一个栈。
struct NarrowNavigation {
    var path: [Route] = []
    var sidebarOpen = false
}

/// 宽屏只有两栏的去处。main 的浏览落点从偏好推出；side 为 nil 就是 Cue。
/// 同一个会话最多在一栏，回复草稿仍按会话 id 由 AppSettings 持有。
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

    var main: Main = .browse
    var side: SessionRoute?
}

extension Workspace {
    enum Layout { case narrow, wide }
    enum Column { case main, side }
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
            case .wide: services.settings.railExpanded
            }
        }
        set {
            switch navigation {
            case .narrow(var state):
                state.sidebarOpen = newValue
                navigation = .narrow(state)
            case .wide: services.settings.railExpanded = newValue
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

    var sideSession: SessionRoute? {
        if case .wide(let state) = navigation { state.side } else { nil }
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

    /// 宽→窄：浏览入口在侧栏，主区详情先入栈，右栏会话在最上。
    /// 窄→宽：栈顶会话进右栏，其下页进主区；否则栈顶或浏览落点进主区。
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
            if let session = state.side { narrow.path.append(.session(session)) }
            navigation = .narrow(narrow)
        case .narrow(let state):
            var wide = WideNavigation()
            if case .session(let session)? = state.path.last {
                wide.side = session
                wide.main = state.path.dropLast().last.map(WideNavigation.Main.init) ?? .browse
            } else if let page = state.path.last {
                wide.main = WideNavigation.Main(page)
            }
            navigation = .wide(wide)
        }
    }
}

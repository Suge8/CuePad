import Foundation

enum NavigationPane: String, CaseIterable {
    case projects, progress
}

/// 窄屏只有以 Cue 为根的一个栈；Cue 不写进 path。侧栏盖在根 Cue 上，推入页盖住二者，不是另一个栈。
/// 边聊边看（`dock`）只活在这个值里：不持久化，换布局、去别处（`selectNarrow`）都建新值，停靠随之解除。
struct NarrowNavigation {
    var path: [Route] = [] { didSet { dock = dock?.following(path) } }
    var sidebarOpen = false { didSet { if sidebarOpen, dock?.session == nil { dock = nil } } }
    var dock: IdeaDock?
}

/// 边聊边看：一条灵感停靠在会话页的回复框上方。`session` 为 nil 时正在 Cue 页的会话条上挑：推入的下一页是会话就停进它，是别的页、打开侧栏即取消。
/// 停进去之后只在那个会话页在最上面时有，返回或再推入别的页即解除：编辑页这时已不在栈里，同一张卡只有停靠里这一个编辑器。
struct IdeaDock: Equatable {
    let card: UUID
    var session: UUID?
    var open = false

    fileprivate func following(_ path: [Route]) -> IdeaDock? {
        guard let top = path.last else { return session == nil ? self : nil }
        guard case .session(let route) = top, session == nil || session == route.id else { return nil }
        var next = self
        next.session = route.id
        return next
    }
}

/// Cue 是落点（`home`，同手机以 Cue 为根）：没去别处时它铺满会话条之外；去了项目、进展或会话，它让到右边——那时它收没收起是用户的选择
/// （`AppSettings.cueOpen`），放不下时住进右缘抽屉、开没开是这一刻的呈现（`Workspace.cueDrawer`）。
/// 同一个会话最多在一边，回复草稿仍按会话 id 由 AppSettings 持有。
struct WideNavigation {
    enum Main {
        /// 浏览落点直接引用持久选择（`browseRoute`），不复制分段。
        case browse
        case session(SessionRoute)
        case page(Route)

        init(_ route: Route) {
            switch route {
            case .shelf, .progress, .cue: self = .browse
            case .session(let session): self = .session(session)
            default: self = .page(route)
            }
        }
    }

    /// 并排时右半边放的：第二个会话，或左边那个会话的活预览。预览属于左边那个会话，左边换了会话就收起；开着预览时再并排一个会话，会话替换它。
    enum Beside: Equatable {
        case session(SessionRoute)
        case preview
    }

    /// Cue 铺满着：主区那一页留着不拆（回去时滚动位置都在），只是让出去、订阅暂停。
    var home = true
    var main: Main = .browse {
        didSet {
            guard case .session(let now) = main else { return beside = nil }
            if beside == .preview, case .session(let before) = oldValue, before.id == now.id { return }
            if beside == .preview { beside = nil }
        }
    }
    /// 主区不是会话时没有（`main` 换走会话时一并清掉）。
    var beside: Beside?

    var besideSession: SessionRoute? { if case .session(let route) = beside { route } else { nil } }
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

    /// 尺寸切换时旧视图的绑定写回不改新布局。
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

    var shownPane: NavigationPane? {
        if cueHome { return nil }
        return switch mainRoute {
        case .shelf, .project: .projects
        case .progress: .progress
        default: nil
        }
    }

    var besideSession: SessionRoute? {
        if case .wide(let state) = navigation { state.besideSession } else { nil }
    }

    var beside: WideNavigation.Beside? {
        if case .wide(let state) = navigation, !state.home { state.beside } else { nil }
    }

    var cueHome: Bool {
        if case .wide(let state) = navigation { state.home } else { false }
    }

    var navigationPane: NavigationPane { services.settings.navigationPane }
    var sidebarRoute: Route { navigationPane == .projects ? .shelf : .progress }
    var browseRoute: Route { Self.browseRoute(services.settings) }

    /// 「项目」只表示项目列表：上次看的项目只决定新记灵感默认进哪（`AppSettings.currentProject`），不决定落点。
    static func browseRoute(_ settings: AppSettings) -> Route {
        switch settings.navigationPane {
        case .projects: .shelf
        case .progress: .progress
        }
    }

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
        case .shelf: services.settings.navigationPane = .projects
        case .progress: services.settings.navigationPane = .progress
        default: break
        }
    }

    /// 宽→窄：浏览入口在侧栏，主区详情先入栈，并排的第二个会话、盖在主区上的页依次在上面。
    /// 窄→宽：栈顶的编辑页、文件页盖到主区上（`overlay`），其下的栈顶或浏览落点进主区（会话独占主区，其下的页回到浏览落点）。
    /// 只转换此刻的导航，不缓存旧布局。
    func setLayout(_ next: Layout) {
        guard next != layout else { return }
        switch navigation {
        case .wide(let state):
            var narrow: NarrowNavigation
            switch mainRoute {
            case _ where state.home: narrow = NarrowNavigation()
            case .shelf, .progress: narrow = NarrowNavigation(sidebarOpen: true)
            case .project: narrow = NarrowNavigation(path: [mainRoute], sidebarOpen: true)
            default: narrow = NarrowNavigation(path: [mainRoute])
            }
            if !state.home, let session = state.besideSession { narrow.path.append(.session(session)) }
            if let overlay { narrow.path.append(overlay.route) }
            overlay = nil
            navigation = .narrow(narrow)
        case .narrow(var state):
            let covering = state.path.last.flatMap(Overlay.init)
            if covering != nil { state.path.removeLast() }
            var wide = WideNavigation(home: state.path.isEmpty && !state.sidebarOpen && covering == nil)
            if let page = state.path.last { wide.main = WideNavigation.Main(page) }
            navigation = .wide(wide)
            overlay = covering
        }
    }
}

extension Workspace.Navigation {
    var trail: String {
        switch self {
        case .narrow(let state): return (["cue"] + state.path.map(\.trail)).joined(separator: " > ") + (state.sidebarOpen ? " + sidebar" : "")
        case .wide(let state):
            if state.home { return "wide cue" }
            return switch state.main {
            case .browse: "wide browse"
            case .session:
                switch state.beside {
                case nil: "wide session"
                case .session: "wide session | session"
                case .preview: "wide session | preview"
                }
            case .page(let route): "wide \(route.trail)"
            }
        }
    }
}

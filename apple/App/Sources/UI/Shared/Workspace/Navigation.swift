import Foundation

enum NavigationPane: String, CaseIterable {
    case projects, progress
}

/// 窄屏只有以 Cue 为根的一个栈；Cue 不写进 path。侧栏盖在根 Cue 上，推入页盖住二者，不是另一个栈。
struct NarrowNavigation {
    var path: [Route] = []
    var sidebarOpen = false
}

/// Cue 是落点（`home`，同手机以 Cue 为根）：没去别处时它铺满会话条之外；去了项目、进展或会话，它让到右边——那时它收没收起是用户的选择
/// （`AppSettings.cueOpen`），放不下时住进右缘抽屉、开没开是这一刻的呈现（`Workspace.cueDrawer`）。
/// 同一个会话最多占一块，回复草稿仍按会话 id 由 AppSettings 持有。
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

    /// 并排时主区右边的几块，从左到右：别的会话、左边那个会话的活预览、灵感。最左那块（`main`）只能是会话：并排是围着一个会话干活，
    /// 看的东西摆在它旁边。预览属于最左那个会话，它换了会话就收起；同一个会话、同一条灵感最多占一块。
    enum Beside: Hashable {
        case session(SessionRoute)
        case preview
        case card(UUID)
    }

    /// 主区最多几块（含最左那块）；窗口放得下几块由宽屏的根量出来报给工作区（`Workspace.wideRoom`）。
    static let maxPanes = 3

    /// Cue 铺满着：主区那一页留着不拆（回去时滚动位置都在），只是让出去、订阅暂停。
    var home = true
    var main: Main = .browse {
        didSet {
            guard case .session(let now) = main else { return beside = [] }
            if case .session(let before) = oldValue, before.id == now.id { return }
            beside.removeAll { $0 == .preview || $0 == .session(now) }
        }
    }
    /// 主区不是会话时为空（`main` 换走会话时一并清掉）。
    var beside: [Beside] = []

    var mainSession: SessionRoute? { if case .session(let route) = main { route } else { nil } }
    var besideSessions: [SessionRoute] { beside.compactMap { if case .session(let route) = $0 { route } else { nil } } }

    /// 把一块放到主区第 `index` 块（0 是最左）：`replacing` 换掉那一块，否则插在那里、后面的往右挪，多出 `room` 的挤掉最右那块（不挤刚放的）。
    /// 已在主区的挪过去：换掉时两块对调，插入时从原处拿走。放完最左不是会话的不放（灵感、预览不能在最左）；最左换了会话时它的预览收起。
    mutating func place(_ pane: Beside, at index: Int, replacing: Bool, room: Int) {
        guard let first = mainSession else { return }
        var panes: [Beside] = [.session(first)] + beside
        var index = min(max(0, index), panes.count - (replacing ? 1 : 0))
        if let old = panes.firstIndex(of: pane) {
            if replacing {
                panes.swapAt(old, index)
            } else {
                panes.remove(at: old)
                if old < index { index -= 1 }
                panes.insert(pane, at: index)
            }
        } else if replacing {
            panes[index] = pane
        } else {
            panes.insert(pane, at: index)
            if panes.count > max(1, room) { panes.remove(at: index == panes.count - 1 ? panes.count - 2 : panes.count - 1) }
        }
        guard case .session(let lead) = panes[0] else { return }
        if lead.id != first.id { panes.removeAll { $0 == .preview } }
        main = .session(lead)
        beside = Array(panes.dropFirst())
    }

    /// 开合最左那个会话的活预览：开在它紧右边，放满了挤掉最右那块。
    mutating func togglePreview(room: Int) {
        if beside.contains(.preview) {
            beside.removeAll { $0 == .preview }
        } else {
            place(.preview, at: 1, replacing: false, room: room)
        }
    }

    /// 收起第 `index` 块（0 是最左）：最左那块收起时右边第一个会话补上，右边没有会话就回到 Cue。
    mutating func close(at index: Int) {
        guard index > 0 else {
            guard let next = besideSessions.first else {
                main = .browse
                home = true
                return
            }
            beside.removeAll { $0 == .session(next) }
            main = .session(next)
            return
        }
        if beside.indices.contains(index - 1) { beside.remove(at: index - 1) }
    }
}

extension Workspace {
    enum Layout { case narrow, wide }
    /// 主区里的一块：`main` 是最左那块（只开一个时就是整个主区），`beside(i)` 是并排时它右边的第 i 块（从 0 起）。
    enum Column: Hashable {
        case main
        case beside(Int)

        /// 开在旁边（⌘ 点、"并排打开"）：放得下就在最右添一块，放不下换掉最右那块。
        static let aside = Column.beside(WideNavigation.maxPanes)

        /// 在主区几块里的序号（0 是最左）。
        var index: Int {
            switch self {
            case .main: 0
            case .beside(let index): index + 1
            }
        }

        init(index: Int) { self = index == 0 ? .main : .beside(index - 1) }
    }
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

    var besideSessions: [SessionRoute] {
        if case .wide(let state) = navigation { state.besideSessions } else { [] }
    }

    var beside: [WideNavigation.Beside] {
        if case .wide(let state) = navigation, !state.home { state.beside } else { [] }
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

    /// 宽→窄：浏览入口在侧栏，主区详情先入栈，并排的几块（会话、灵感；预览不留）、盖在主区上的页依次在上面。
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
            if !state.home {
                for pane in state.beside {
                    switch pane {
                    case .session(let session): narrow.path.append(.session(session))
                    case .card(let id): narrow.path.append(.card(id))
                    case .preview: break
                    }
                }
            }
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
                (["wide session"] + state.beside.map { pane in
                    switch pane {
                    case .session: "session"
                    case .preview: "preview"
                    case .card: "card"
                    }
                }).joined(separator: " | ")
            case .page(let route): "wide \(route.trail)"
            }
        }
    }
}

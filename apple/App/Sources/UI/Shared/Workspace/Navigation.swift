import Foundation

enum NavigationPane: String, CaseIterable {
    case projects, progress
}

struct NarrowNavigation: Equatable {
    var path: [Route] = [] { didSet { dock = dock?.following(path) } }
    var sidebarOpen = false { didSet { if sidebarOpen, dock?.session == nil { dock = nil } } }
    var dock: IdeaDock?
}

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

/// 宽屏主区从左到右的几块（`panes`，不空，窗口放得下时最多 `maxPanes` 块）。块是平等的：页、会话、灵感、活预览，谁都可以在最左。
/// 页至多一块；独占的页（进展）自己一排，不与别的并排。一个会话、一条灵感只在一处。活预览至多一块，紧挨在它的会话右边，会话离开这一排它也走。
struct WideNavigation: Equatable {
    enum Pane: Hashable {
        case page(Route)
        case session(SessionRoute)
        case card(UUID)
        case preview(UUID)

        var page: Route? { if case .page(let route) = self { route } else { nil } }
        var session: SessionRoute? { if case .session(let route) = self { route } else { nil } }
        var card: UUID? { if case .card(let id) = self { id } else { nil } }
        var previewed: UUID? { if case .preview(let session) = self { session } else { nil } }
        var standsAlone: Bool { page == .progress }

        var route: Route? {
            switch self {
            case .page(let route): route
            case .session(let session): .session(session)
            case .card(let id): .card(id)
            case .preview: nil
            }
        }
    }

    static let maxPanes = 3
    static let empty = Pane.page(.progress)

    var panes: [Pane] = [empty] {
        didSet {
            var next = panes
            if let at = next.firstIndex(where: { $0.previewed != nil }) {
                let preview = next.remove(at: at)
                if let owner = next.firstIndex(where: { $0.session?.id == preview.previewed }) { next.insert(preview, at: owner + 1) }
            }
            if next.isEmpty { next = [Self.empty] }
            if next != panes { panes = next }
        }
    }

    init(_ panes: [Pane] = [empty]) {
        self.panes = panes.isEmpty ? [Self.empty] : panes
    }

    var page: Route? { panes.lazy.compactMap(\.page).first }
    var sessions: [SessionRoute] { panes.compactMap(\.session) }
    var cards: [UUID] { panes.compactMap(\.card) }
    var preview: UUID? { panes.lazy.compactMap(\.previewed).first }
    /// 挂着的页与盖在页上的那一层所在的那一块：页；页不在这一排时是最左。
    var host: Int { panes.firstIndex { $0.page != nil } ?? 0 }

    /// 选一页：这一排里有页就原地换它，别的块留着；没有页、或选的是独占的页，整排换成它。
    mutating func select(_ route: Route) {
        let pane = Pane.page(route)
        if let index = panes.firstIndex(where: { $0.page != nil }), !pane.standsAlone { panes[index] = pane } else { panes = [pane] }
    }

    /// 在最左打开：已在这一排的挪过来，换掉原来最左那块。
    mutating func open(_ pane: Pane) {
        guard panes[0] != pane else { return }
        var next = panes.filter { $0 != pane }
        next[0] = pane
        panes = next
    }

    /// 放到第 `index` 块的位置：`replacing` 换掉那块（已在这一排的两块对调），否则插在它前面。多出 `room` 块时挤掉最右一块（不挤刚放的，也不挤活预览的会话）。
    /// 会话与它的活预览挪位置时是一个整体（`anchor`）：挪活预览、与活预览对调，都是它的会话在对调，活预览照旧跟过去。
    /// 独占的页旁边不放东西，只能换掉它。
    @discardableResult mutating func place(_ pane: Pane, at index: Int, replacing: Bool, room: Int) -> Bool {
        var next = panes
        var index = min(max(0, index), next.count - (replacing ? 1 : 0))
        if next.contains(where: \.standsAlone), !replacing { return false }
        if let old = next.firstIndex(of: pane) {
            if replacing {
                next.swapAt(anchor(old), anchor(index))
            } else {
                next.remove(at: old)
                if old < index { index -= 1 }
                next.insert(pane, at: index)
            }
        } else if replacing {
            next[index] = pane
        } else {
            next.insert(pane, at: index)
            if next.count > max(1, room), let spare = next.lastIndex(where: { $0 != pane && !($0.session.map { $0.id == pane.previewed } ?? false) }) { next.remove(at: spare) }
        }
        panes = next
        return true
    }

    /// 第 `index` 块算在哪一块上：活预览算在它的会话上，别的就是自己。
    func anchor(_ index: Int) -> Int {
        panes[index].previewed.flatMap { session in panes.firstIndex { $0.session?.id == session } } ?? index
    }

    func dropping(_ pane: Pane, at index: Int, replacing: Bool, room: Int) -> WideNavigation? {
        var next = self
        guard next.place(pane, at: index, replacing: replacing, room: room), next != self else { return nil }
        return next
    }

    mutating func togglePreview(of session: UUID, room: Int) {
        let open = preview == session
        var next = self
        next.panes.removeAll { $0.previewed != nil }
        if !open, let owner = next.panes.firstIndex(where: { $0.session?.id == session }) {
            next.place(.preview(session), at: owner + 1, replacing: false, room: max(2, room))
        }
        self = next
    }

    mutating func close(at index: Int) {
        guard panes.indices.contains(index) else { return }
        panes.remove(at: index)
    }
}

extension Workspace {
    enum Layout { case narrow, wide }
    enum Column: Hashable {
        case main
        case beside(Int)

        static let aside = Column.beside(WideNavigation.maxPanes)

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
        case .wide(let state): state.panes.lazy.compactMap(\.route).first ?? .progress
        }
    }

    var panes: [WideNavigation.Pane] {
        if case .wide(let state) = navigation { state.panes } else { [] }
    }

    /// 宽屏这一排里的那一页；页不在这一排（或窄屏）时为 nil。
    var pageRoute: Route? {
        if case .wide(let state) = navigation { state.page } else { nil }
    }

    /// 挂着的页与盖在页上的那一层画在哪一块（`WideNavigation.host`）。
    var pageHost: Column {
        if case .wide(let state) = navigation { Column(index: state.host) } else { .main }
    }

    var shownPane: NavigationPane? {
        switch pageRoute ?? mainRoute {
        case .shelf, .project: .projects
        case .progress: .progress
        default: nil
        }
    }

    var navigationPane: NavigationPane { services.settings.navigationPane }
    var sidebarRoute: Route { navigationPane == .projects ? .shelf : .progress }
    var browseRoute: Route { Self.browseRoute(services.settings) }

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

    func setLayout(_ next: Layout) {
        guard next != layout else { return }
        switch navigation {
        case .wide(let state):
            var narrow: NarrowNavigation
            switch state.page {
            case .shelf?, .progress?: narrow = NarrowNavigation(sidebarOpen: true)
            case .project(let id)?: narrow = NarrowNavigation(path: [.project(id)], sidebarOpen: true)
            case let page?: narrow = NarrowNavigation(path: [page])
            case nil: narrow = NarrowNavigation()
            }
            for session in state.sessions { narrow.path.append(.session(session)) }
            if let card = state.cards.first {
                if case .session(let top)? = narrow.path.last { narrow.dock = IdeaDock(card: card, session: top.id) } else { narrow.path.append(.card(card)) }
            }
            if let overlay { narrow.path.append(overlay.route) }
            widened = (narrow, state, overlay)
            overlay = nil
            navigation = .narrow(narrow)
        case .narrow(var state):
            defer { widened = nil }
            if let widened, widened.narrow == state {
                navigation = .wide(widened.wide)
                overlay = widened.overlay
                return
            }
            let covering = state.path.last.flatMap(Overlay.init)
            if covering != nil { state.path.removeLast() }
            var wide = WideNavigation()
            let dock = state.dock.flatMap { $0.session == nil ? nil : $0.card }
            let sessions = state.path.reversed().prefix { if case .session = $0 { true } else { false } }.prefix(WideNavigation.maxPanes - (dock == nil ? 0 : 1)).reversed()
            if !sessions.isEmpty {
                wide = WideNavigation(sessions.compactMap { if case .session(let route) = $0 { .session(route) } else { nil } } + (dock.map { [.card($0)] } ?? []))
            } else if let page = state.path.last {
                wide = WideNavigation(page == .cue ? [] : [.page(page)])
            } else if state.sidebarOpen {
                wide = WideNavigation([.page(browseRoute)])
            }
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
            return "wide " + state.panes.map { pane in
                switch pane {
                case .page(let route): route.trail
                case .session: "session"
                case .card: "card"
                case .preview: "preview"
                }
            }.joined(separator: " | ")
        }
    }
}

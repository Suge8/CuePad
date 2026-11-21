import Foundation

enum NavigationPane: String, CaseIterable {
    case projects, progress
}

struct NarrowNavigation {
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

struct WideNavigation: Equatable {
    enum Main: Equatable {
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

    enum Beside: Hashable {
        case session(SessionRoute)
        case preview
        case card(UUID)
    }

    static let maxPanes = 3

    var home = true
    var main: Main = .browse {
        didSet {
            guard case .session(let now) = main else { return beside = [] }
            if case .session(let before) = oldValue, before.id == now.id { return }
            beside.removeAll { $0 == .preview || $0 == .session(now) }
        }
    }
    var beside: [Beside] = []

    var mainSession: SessionRoute? { if case .session(let route) = main { route } else { nil } }
    var besideSessions: [SessionRoute] { beside.compactMap { if case .session(let route) = $0 { route } else { nil } } }

    @discardableResult mutating func place(_ pane: Beside, at index: Int, replacing: Bool, room: Int) -> Bool {
        guard let first = mainSession else { return false }
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
        guard case .session(let lead) = panes[0] else { return false }
        if lead.id != first.id { panes.removeAll { $0 == .preview } }
        main = .session(lead)
        beside = Array(panes.dropFirst())
        return true
    }

    func dropping(_ pane: Beside, at index: Int, replacing: Bool, room: Int, covering: UUID?) -> WideNavigation? {
        var next = self
        next.home = false
        if case .session(let session) = pane, mainSession == nil || covering != nil && index == 0 {
            next.beside.removeAll { $0 == pane }
            next.main = .session(session)
            if let covering, !next.place(.card(covering), at: 1, replacing: false, room: room) { return nil }
        } else if !next.place(pane, at: index, replacing: replacing, room: room) {
            return nil
        }
        return next == self ? nil : next
    }

    var panes: [Beside] { mainSession.map { [.session($0)] + beside } ?? [] }

    mutating func togglePreview(room: Int) {
        if beside.contains(.preview) {
            beside.removeAll { $0 == .preview }
        } else {
            place(.preview, at: 1, replacing: false, room: max(2, room))
        }
    }

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
            switch mainRoute {
            case _ where state.home: narrow = NarrowNavigation()
            case .shelf, .progress: narrow = NarrowNavigation(sidebarOpen: true)
            case .project: narrow = NarrowNavigation(path: [mainRoute], sidebarOpen: true)
            default: narrow = NarrowNavigation(path: [mainRoute])
            }
            if !state.home {
                for session in state.besideSessions { narrow.path.append(.session(session)) }
                let card = state.beside.lazy.compactMap { if case .card(let id) = $0 { id } else { nil } }.first
                if let card, case .session(let top)? = narrow.path.last { narrow.dock = IdeaDock(card: card, session: top.id) }
            }
            if let overlay { narrow.path.append(overlay.route) }
            overlay = nil
            navigation = .narrow(narrow)
        case .narrow(var state):
            let covering = state.path.last.flatMap(Overlay.init)
            if covering != nil { state.path.removeLast() }
            var wide = WideNavigation(home: state.path.isEmpty && !state.sidebarOpen && covering == nil)
            let dock = state.dock.flatMap { $0.session == nil ? nil : $0.card }
            let sessions = state.path.reversed().prefix { if case .session = $0 { true } else { false } }.prefix(WideNavigation.maxPanes - (dock == nil ? 0 : 1)).reversed()
            if case .session(let first)? = sessions.first {
                wide.main = .session(first)
                wide.beside = sessions.dropFirst().compactMap { if case .session(let route) = $0 { .session(route) } else { nil } }
                if let dock { wide.beside.append(.card(dock)) }
            } else if let page = state.path.last {
                wide.main = WideNavigation.Main(page)
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

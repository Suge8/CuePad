import CueStore
import Foundation
import Observation

extension Workspace {
    var top: Route { mainRoute }

    var currentProject: UUID? {
        let routes = layout == .narrow ? path : [mainRoute]
        return routes.reversed().compactMap { route in
            if case .project(let id) = route { id } else { nil }
        }.first
    }

    var shownSessions: [ViewerKeeper.Page] {
        let sessions: [SessionRoute]
        switch navigation {
        case .narrow(let state):
            if case .session(let route)? = state.path.last { sessions = [route] } else { sessions = [] }
        case .wide(let state):
            sessions = [state.mainSession].compactMap(\.self) + state.besideSessions
        }
        return sessions.map { ViewerKeeper.Page(id: $0.id, sessionID: $0.sessionID) }
    }

    func show(_ route: Route) {
        openTask = nil
        switch layout {
        case .narrow: showNarrow(route)
        case .wide: selectWide(route)
        }
    }

    func select(_ route: Route) {
        openTask = nil
        switch layout {
        case .narrow: selectNarrow(route)
        case .wide: selectWide(route)
        }
    }

    func push(_ route: Route) {
        switch layout {
        case .narrow: pushNarrow(route)
        case .wide: selectWide(route)
        }
    }

    func leave(_ route: Route) {
        switch route {
        case .card(let id):
            close(.card(id))
            if openTask?.task == id { openTask = nil }
        case .libraryFile(let file): close(.library(file))
        default: break
        }
        switch navigation {
        case .narrow(var state):
            let index = state.path.firstIndex(of: route)
            let docked = if case .card(let id) = route { state.dock?.card == id } else { false }
            guard index != nil || docked else { return }
            if docked { state.dock = nil }
            if let index { state.path = Array(state.path[..<index]) }
            navigation = .narrow(state)
        case .wide(var state):
            if case .card(let id) = route, state.beside.contains(.card(id)) {
                state.beside.removeAll { $0 == .card(id) }
                navigation = .wide(state)
                return
            }
            guard case .page(route) = state.main else { return }
            selectWide(browseRoute)
        }
    }

    func back() {
        switch layout {
        case .narrow: if !path.isEmpty { path.removeLast() }
        case .wide: if overlay != nil { overlay = nil } else { closeColumn(.main) }
        }
    }

    func showProgress(of project: UUID) {
        projectScope = project
        selectPane(.progress)
    }

    func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let id, let sessionID): openSession(id, sessionID: sessionID)
        case .task(let id): openTask(id: id)
        case .schedules: cue.showsSchedules = true
        }
    }

    func open(_ card: Card) {
        if card.isTask { return openTask(card) }
        openTask = nil
        showEditor(card.id)
    }

    func openSession(_ id: UUID, sessionID: String? = nil, in column: Column = .main) {
        guard let route = sessionRoute(id, sessionID: sessionID) else { return }
        openTask = nil
        switch layout {
        case .narrow: showNarrow(route)
        case .wide:
            if case .session(let session) = route { openWideSession(session, in: column) }
        }
    }

    func go(to link: Route) {
        notice = nil
        guard case .session(let route) = link else { return show(link) }
        openSession(route.id, sessionID: route.sessionID)
    }

    func follow(_ next: TaskNext) {
        switch next {
        case .agent(_, let session): openSession(session.id, sessionID: session.sessionID)
        case .start(let leaf): handOff(leaf)
        }
    }

    func showProject(number: Int) {
        guard let projects = catalog?.projects, projects.indices.contains(number - 1) else { return }
        show(.project(projects[number - 1].id))
    }

    func newCard() {
        let project = currentProject ?? Project.defaultID
        attempt { self.open(try await self.createCard(in: project)) }
    }

    func speakToCue() {
        show(.cue)
        cueFocusPending = true
    }

    func open(_ link: DeepLink) {
        switch link {
        case .speak: speakToCue()
        case .project(let id): if let catalog, catalog.project(id) == nil { show(.shelf) } else { show(.project(id)) }
        case .cue: show(.cue)
        case .session(let id): openSession(id)
        case .remoteBound(let device, let error, let nonce): Task { await remoteBound(device: device, error: error, nonce: nonce) }
        case .remoteFailed(let host, let reason): remoteFailed(host: host, reason: reason)
        case .card(let id):
            let store = services.store
            attempt { if let card = try await store.card(id) { self.open(card) } }
        }
    }

    func openLinks() async {
        for await _ in Observations({ self.services.pendingDeepLink }) {
            if let link = services.consumeDeepLink() { open(link) }
        }
    }
}

struct ProjectFormRequest: Identifiable {
    let id = UUID()
    var project: Project?
}

enum LibraryPane: Int, CaseIterable, Comparable {
    case rules, skills

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .rules: "规则"
        case .skills: "技能"
        }
    }

    var icon: Icon {
        switch self {
        case .rules: .instruction
        case .skills: .skill
        }
    }
}

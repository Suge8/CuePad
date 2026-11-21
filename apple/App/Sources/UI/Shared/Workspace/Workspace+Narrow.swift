import Foundation

extension Workspace {
    func setNarrowPath(_ next: [Route]) {
        guard layout == .narrow else { return }
        if let route = next.last { remember(route) }
        path = next
    }

    func showNarrow(_ route: Route) {
        if case .session = route { pushNarrow(route) } else { selectNarrow(route) }
    }

    func selectNarrow(_ route: Route) {
        remember(route)
        switch route {
        case .cue: navigation = .narrow(NarrowNavigation())
        case .shelf, .progress: navigation = .narrow(NarrowNavigation(sidebarOpen: true))
        case .project: navigation = .narrow(NarrowNavigation(path: [route], sidebarOpen: true))
        default: navigation = .narrow(NarrowNavigation(path: [route]))
        }
    }

    func pushNarrow(_ route: Route) {
        switch route {
        case .cue, .shelf, .progress: return selectNarrow(route)
        default: break
        }
        guard case .narrow(var state) = navigation else { return }
        remember(route)
        if let index = state.path.firstIndex(of: route) {
            state.path = Array(state.path[...index])
        } else {
            state.path.append(route)
        }
        navigation = .narrow(state)
    }

    var ideaDock: IdeaDock? { if case .narrow(let state) = navigation { state.dock } else { nil } }
    var pickingDock: Bool { ideaDock.map { $0.session == nil } ?? false }

    func pickDock(_ card: UUID) {
        guard layout == .narrow else { return }
        navigation = .narrow(NarrowNavigation(dock: IdeaDock(card: card)))
        say("选一个会话", tone: .pick, action: NoticeAction(title: String(localized: "取消")) { $0.setDock(nil) })
    }

    func setDock(_ dock: IdeaDock?) {
        guard case .narrow(var state) = navigation else { return }
        state.dock = dock
        navigation = .narrow(state)
    }
}

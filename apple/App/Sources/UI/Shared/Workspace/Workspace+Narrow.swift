extension Workspace {
    /// NavigationLink 和系统返回直接写路径；项目书架的链接也要更新持久浏览落点。
    func setNarrowPath(_ next: [Route]) {
        guard layout == .narrow else { return }
        if let route = next.last { remember(route) }
        path = next
    }

    func showNarrow(_ route: Route) {
        if case .session = route { pushNarrow(route) } else { selectNarrow(route) }
    }

    /// 项目与进展是根上的侧栏；项目详情等页推在根上，返回仍落到侧栏。
    func selectNarrow(_ route: Route) {
        remember(route)
        switch route {
        case .cue: navigation = .narrow(NarrowNavigation())
        case .shelf, .progress: navigation = .narrow(NarrowNavigation(sidebarOpen: true))
        case .project: navigation = .narrow(NarrowNavigation(path: [route], sidebarOpen: true))
        default: navigation = .narrow(NarrowNavigation(path: [route]))
        }
    }

    /// 推入页盖住 Cue 与侧栏；保留根的开合值，系统返回无需另存来源。
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
}

extension Workspace {
    func selectWide(_ route: Route) {
        guard case .wide(var state) = navigation else { return }
        let previous = mainRoute
        switch route {
        case .cue: state.side = nil
        case .session(let session): return openWideSession(session, in: .side)
        default:
            remember(route)
            state.main = WideNavigation.Main(route)
        }
        navigation = .wide(state)
        if route != .cue { willSelect(mainRoute, from: previous) }
    }

    /// 会话已在另一栏时挪过来，不复制。目标栏被替换；源栏回浏览页或 Cue。
    func openWideSession(_ session: SessionRoute, in column: Column) {
        guard case .wide(var state) = navigation else { return }
        openTask = nil
        switch column {
        case .main:
            if state.side?.id == session.id { state.side = nil }
            state.main = .session(session)
        case .side:
            if case .session(let main) = state.main, main.id == session.id { state.main = .browse }
            state.side = session
        }
        presentWide(state)
        #if os(macOS)
        if let alerts = services.alerts { Task { await alerts.dismiss(session: session.id) } }
        #endif
    }

    /// 栏头拖放或键盘挪栏：目标也是会话时交换；目标是浏览页/Cue 时源栏回其固定落点。
    /// focus 不存到导航；调用方把实际有键盘焦点的栏传进来。
    func moveSession(from source: Column, to target: Column) {
        guard source != target, case .wide(var state) = navigation else { return }
        let main: SessionRoute? = if case .session(let session) = state.main { session } else { nil }
        switch source {
        case .main:
            guard let main else { return }
            state.main = state.side.map(WideNavigation.Main.session) ?? .browse
            state.side = main
        case .side:
            guard let side = state.side else { return }
            state.side = main
            state.main = .session(side)
        }
        presentWide(state)
    }

    func session(in column: Column) -> SessionRoute? {
        guard case .wide(let state) = navigation else { return nil }
        if column == .side { return state.side }
        if case .session(let session) = state.main { return session }
        return nil
    }

    /// 同窗口按对象当前位置交换；跨窗口只打开被拖的会话，不改源窗口。
    func dropSession(_ route: SessionRoute, in column: Column, movingWithinWindow: Bool) {
        if movingWithinWindow, let source = [Column.main, .side].first(where: { session(in: $0)?.id == route.id }) {
            moveSession(from: source, to: column)
        } else {
            openSession(route.id, sessionID: route.sessionID, in: column)
        }
    }

    private func presentWide(_ state: WideNavigation) {
        let previous = mainRoute
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    /// 栏头的 ×：左栏回项目｜进展的浏览落点（`browseRoute`，之前打开的项目还是那个），右栏回 Cue。不另存返回来源。
    func closeColumn(_ column: Column) {
        guard case .wide(var state) = navigation else { return }
        switch column {
        case .main: state.main = .browse
        case .side: state.side = nil
        }
        presentWide(state)
    }
}

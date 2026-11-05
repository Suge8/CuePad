extension Workspace {
    func selectWide(_ route: Route) {
        guard case .wide(var state) = navigation else { return }
        let previous = mainRoute
        switch route {
        case .cue: return showCue()
        case .session(let session): return openWideSession(session, in: .main)
        default:
            remember(route)
            state.main = WideNavigation.Main(route)
        }
        cueDrawer = false
        navigation = .wide(state)
        willSelect(mainRoute, from: previous)
    }

    /// 去 Cue（深链、通知、对 Cue 说、收着时点 Cue 钮、⌃⌘I）：放得下就放回右边，放不下拉出抽屉。两样都置上：窗口之后跨过临界宽，Cue 照样露着。
    func showCue() {
        services.settings.cueOpen = true
        cueDrawer = true
    }

    /// 宽屏会话条开着（用户的选择，只有一份）。
    var railExpanded: Bool {
        get { services.settings.railExpanded }
        set { services.settings.railExpanded = newValue }
    }

    /// 收起露着的 Cue（Cue 栏头最右那颗、iPad 的 Cue 钮、⌃⌘I）：在抽屉里（放不下，`fits` 为假）只关抽屉，不改用户放不放回右边的选择；在右边的收成钮。
    func hideCue(fits: Bool) {
        cueDrawer = false
        if fits { services.settings.cueOpen = false }
    }

    /// Cue 此刻露着：在右边，或抽屉开着。
    func cueShown(_ sizes: WideMetrics) -> Bool { sizes.cue > 0 || !sizes.cueFits && cueDrawer }

    /// ⌃⌘I（"显示 › 右栏"）：按这个窗口此刻的尺寸（`WideMetrics`）收起或放回。
    func toggleCue(_ sizes: WideMetrics) {
        if cueShown(sizes) { hideCue(fits: sizes.cueFits) } else { showCue() }
    }

    /// 会话已在另一边时挪过来、不复制。`main` 替换左半（右半是它时右半关掉）；`beside` 在主区已是别的会话时开在右半并排，否则同 `main`。
    func openWideSession(_ session: SessionRoute, in column: Column) {
        guard case .wide(var state) = navigation else { return }
        openTask = nil
        let main: SessionRoute? = if case .session(let route) = state.main { route } else { nil }
        switch column {
        case .beside where main != nil:
            if main?.id != session.id { state.beside = session }
        case .beside, .main:
            if state.beside?.id == session.id { state.beside = nil }
            state.main = .session(session)
        }
        presentWide(state)
        #if os(macOS)
        if let alerts = services.alerts { Task { await alerts.dismiss(session: session.id) } }
        #endif
    }

    /// 栏头拖放或键盘挪：并排的两个会话换边；只开一个时没有可换的。
    /// focus 不存到导航；调用方把实际有键盘焦点的那一边传进来。
    func moveSession(from source: Column, to target: Column) {
        guard source != target, case .wide(var state) = navigation, case .session(let main) = state.main, let beside = state.beside else { return }
        state.main = .session(beside)
        state.beside = main
        presentWide(state)
    }

    func session(in column: Column) -> SessionRoute? {
        guard case .wide(let state) = navigation else { return nil }
        if column == .beside { return state.beside }
        if case .session(let session) = state.main { return session }
        return nil
    }

    /// 同窗口按对象当前位置换边；跨窗口只打开被拖的会话，不改源窗口。
    func dropSession(_ route: SessionRoute, in column: Column, movingWithinWindow: Bool) {
        if movingWithinWindow, let source = [Column.main, .beside].first(where: { session(in: $0)?.id == route.id }) {
            moveSession(from: source, to: column)
        } else {
            openSession(route.id, sessionID: route.sessionID, in: column)
        }
    }

    private func presentWide(_ state: WideNavigation) {
        let previous = mainRoute
        cueDrawer = false
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    /// 会话栏头的 ×：关左半时右半的会话占满主区，只有一个时回项目列表或进展（`browseRoute`）；关右半回到只开一个。不另存返回来源。
    func closeColumn(_ column: Column) {
        guard case .wide(var state) = navigation else { return }
        switch column {
        case .main:
            let beside = state.beside
            state.beside = nil
            state.main = beside.map(WideNavigation.Main.session) ?? .browse
        case .beside: state.beside = nil
        }
        presentWide(state)
    }
}

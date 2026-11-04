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
        cueFloats = false
        navigation = .wide(state)
        willSelect(mainRoute, from: previous)
    }

    /// 去 Cue（深链、通知、对 Cue 说）：用户收起的放回右边；窗口放不下时从右边浮出、盖在主区上（`cueFloats`，放得下时它不起作用，换主区时收回）。
    func showCue() {
        services.settings.cueOpen = true
        cueFloats = true
    }

    /// 宽屏会话条开着（用户的选择）：主区放着看板时读写看板那一份，别处读写另一份（`WideMetrics` 头注释的规则）。
    var railExpanded: Bool {
        get { onBoard ? services.settings.boardRailExpanded : services.settings.railExpanded }
        set { if onBoard { services.settings.boardRailExpanded = newValue } else { services.settings.railExpanded = newValue } }
    }

    /// 主区放着进展的看板（会话条的开合按看板那一份算）。
    var onBoard: Bool { mainRoute == .progress }

    /// 收起露着的 Cue（Mac 栏头的收起右栏、iPad 的 Cue 钮、⌃⌘I）：浮出来的收回，放在右边的收起（用户的选择，`AppSettings.cueOpen`）。
    func hideCue() {
        if cueFloats { cueFloats = false } else { services.settings.cueOpen = false }
    }

    /// 放回收着的 Cue（Cue 钮、⌃⌘I）：放得下放回右边（用户的选择），放不下从右边浮出（这一刻的呈现）。
    func revealCue(fits: Bool) {
        if fits { services.settings.cueOpen = true } else { cueFloats = true }
    }

    /// ⌃⌘I（"显示 › 右栏"）：按这个窗口此刻的尺寸（`WideMetrics`）收起或放回。
    func toggleCue(_ sizes: WideMetrics) {
        if sizes.cueShown { hideCue() } else { revealCue(fits: sizes.cueFits) }
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
        cueFloats = false
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    /// 会话栏头的 ×：关左半时右半的会话占满主区，只有一个时回项目｜进展的浏览落点（`browseRoute`，之前打开的项目还是那个）；关右半回到只开一个。不另存返回来源。
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

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
        state.home = false
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
        willSelect(mainRoute, from: previous)
    }

    /// 回到 Cue 铺满（会话条最上那一行）：主区的页留着，再点它那一行就回去。
    func goHome() {
        guard case .wide(var state) = navigation, !state.home else { return }
        openTask = nil
        state.home = true
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
    }

    /// 会话条的开合钮与 ⌃⌘S：放得下时开合用户的选择（`railExpanded`），放不下时拉出、收回左缘的抽屉（`railDrawer`），同 Cue 放不下时的右缘抽屉。
    func toggleRail(_ sizes: WideMetrics) {
        if sizes.railFits {
            railDrawer = false
            railExpanded.toggle()
        } else {
            railDrawer.toggle()
        }
    }

    func railShown(_ sizes: WideMetrics) -> Bool { sizes.rail > 0 || !sizes.railFits && railDrawer }

    /// 去 Cue（深链、通知、对 Cue 说、收着时点 Cue 钮、⌃⌘I）：放回右边（用户的选择），此刻放不下再拉出抽屉。
    /// 放得下时不置抽屉位：它只说"放不下的这一段里抽屉开着"，留着的话窗口之后变窄，抽屉会自己滑出来。
    func showCue() {
        services.settings.cueOpen = true
        if wideFits?.cue != true { cueDrawer = true }
    }

    /// 窗口放不放得下变了（`reportsWideFits`）：跨过临界宽（放得下↔放不下）的那一刻关掉对应的抽屉，放得下时抽屉位恒为假——
    /// 抽屉开着说的是"放不下的这一段里拉出来了"，跨出这一段就作废；不清的话拉宽再拖窄，抽屉会自己又出来。两个抽屉同一条规则，只在这里清。
    /// 第一次报（还没排过版）放不下时不清：启动时就窄的窗口里，摆画面拉出的抽屉要留着。
    func fit(_ fits: WideMetrics.Fits) {
        let previous = wideFits
        wideFits = fits
        if fits.rail || previous.map({ $0.rail != fits.rail }) == true { railDrawer = false }
        if fits.cue || previous.map({ $0.cue != fits.cue }) == true { cueDrawer = false }
    }

    var railExpanded: Bool {
        get { services.settings.railExpanded }
        set { services.settings.railExpanded = newValue }
    }

    /// 收起露着的 Cue（Cue 栏头最右那颗、iPad 的 Cue 钮、⌃⌘I）：在抽屉里（放不下，`fits` 为假）只关抽屉，不改用户放不放回右边的选择；在右边的收成钮。
    func hideCue(fits: Bool) {
        cueDrawer = false
        if fits, !cueHome { services.settings.cueOpen = false }
    }

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
        state.home = false
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
        railDrawer = false
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    /// 并排时栏头的 ×：关左半时右半的会话占满主区，关右半回到只开一个。只开一个时没有 ×（换去处靠会话条），键盘的返回回到 Cue。不另存返回来源。
    func closeColumn(_ column: Column) {
        guard case .wide(var state) = navigation else { return }
        switch column {
        case .main:
            let beside = state.beside
            state.beside = nil
            if let beside { state.main = .session(beside) } else { state.main = .browse; state.home = true }
        case .beside: state.beside = nil
        }
        presentWide(state)
    }
}

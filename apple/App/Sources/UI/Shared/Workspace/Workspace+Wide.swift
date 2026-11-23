extension Workspace {
    func selectWide(_ route: Route) {
        guard case .wide(var state) = navigation else { return }
        switch route {
        case .cue: return showCue()
        case .session(let session): return openWideSession(session, in: .main)
        case .card, .libraryFile: return present(Overlay(route)!)
        default:
            remember(route)
            state.select(route)
        }
        overlay = nil
        presentWide(revealingHost(state))
    }

    func present(_ page: Overlay) {
        if case .card(let id) = page, panes.contains(.card(id)) { return }
        #if os(macOS)
        presses.clearSelection()
        #endif
        revealHost()
        overlay = page
    }

    /// 页那一块排在看得见的几块之后（窗口窄，最右的藏起）时挪到最左：刚选的页、盖在页上的那一层要看得见。别的块顺次右移，不丢。
    private func revealingHost(_ state: WideNavigation) -> WideNavigation {
        guard let width = wideFits?.width, state.host >= WideMetrics(width: width, workspace: self, navigation: state).widths.count else { return state }
        var state = state
        state.panes.insert(state.panes.remove(at: state.host), at: 0)
        return state
    }

    private func revealHost() {
        guard case .wide(let state) = navigation else { return }
        let shown = revealingHost(state)
        if shown != state { navigation = .wide(shown) }
    }

    func toggleRail(_ sizes: WideMetrics) {
        if sizes.railFits {
            railDrawer = false
            railExpanded.toggle()
        } else {
            railDrawer.toggle()
        }
    }

    func railShown(_ sizes: WideMetrics) -> Bool { sizes.rail > 0 || !sizes.railFits && railDrawer }

    func showCue() {
        services.settings.cueOpen = true
        if wideFits?.cue != true { cueDrawer = true }
    }

    func fit(_ fits: WideMetrics.Fits) {
        let previous = wideFits
        wideFits = fits
        if railDrawer, fits.rail || previous.map({ $0.rail != fits.rail }) == true { railDrawer = false }
        if cueDrawer, fits.cue || previous.map({ $0.cue != fits.cue }) == true { cueDrawer = false }
        if overlay != nil { revealHost() }
    }

    var railExpanded: Bool {
        get { services.settings.railExpanded }
        set { services.settings.railExpanded = newValue }
    }

    func hideCue(fits: Bool) {
        cueDrawer = false
        if fits { services.settings.cueOpen = false }
    }

    func cueShown(_ sizes: WideMetrics) -> Bool { sizes.cue > 0 || !sizes.cueFits && cueDrawer }

    var cueVisible: Bool { wideSizes.map(cueShown) ?? false }

    /// 右栏放得下时开合它，放不下时拉出、收起抽屉：会话条上的 Cue 格与 ⌃⌘I 同一个动作。
    func toggleCue() {
        guard let sizes = wideSizes else { return }
        if cueShown(sizes) { hideCue(fits: sizes.cueFits) } else { showCue() }
    }

    /// `.main`：在最左打开。旁边的块：开在第 `column` 块的位置，那里已有就换掉它，没有就添一块；放满了换掉最右那块。独占的页旁边不并排，照最左打开。
    func openWideSession(_ session: SessionRoute, in column: Column) {
        guard case .wide(var state) = navigation else { return }
        openTask = nil
        let pane = WideNavigation.Pane.session(session)
        if column == .main || wideRoom < 2 || state.panes[0].standsAlone {
            state.open(pane)
        } else if !state.panes.contains(pane) {
            let shown = wideShown, full = shown >= wideRoom
            let at = column.index < shown ? column.index : full ? shown - 1 : shown
            state.place(pane, at: at, replacing: column.index < shown || full, room: wideRoom)
        }
        presentWide(state)
    }

    @discardableResult func drop(_ pane: WideNavigation.Pane, at index: Int, replacing: Bool) -> Bool {
        guard case .wide(let state) = navigation, let next = state.dropping(pane, at: index, replacing: replacing, room: wideRoom) else { return false }
        openTask = nil
        presentWide(next)
        return true
    }

    func moveColumn(_ column: Column, by step: Int) -> Bool {
        guard case .wide(let state) = navigation, let pane = pane(in: column) else { return false }
        let target = column.index + step
        guard target >= 0, target < wideShown, let next = state.dropping(pane, at: target, replacing: true, room: wideRoom) else { return false }
        presentWide(next)
        return true
    }

    func pane(in column: Column) -> WideNavigation.Pane? {
        let panes = panes
        return panes.indices.contains(column.index) ? panes[column.index] : nil
    }

    func session(in column: Column) -> SessionRoute? { pane(in: column)?.session }

    private var wideSizes: WideMetrics? { wideFits.map { WideMetrics(width: $0.width, workspace: self) } }

    var wideRoom: Int { wideSizes?.room ?? 2 }

    /// 窗口里看得见几块（窗口窄时最右的藏起）。
    var wideShown: Int { wideSizes?.widths.count ?? panes.count }

    private func presentWide(_ state: WideNavigation) {
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
    }

    func closeColumn(_ column: Column) {
        guard case .wide(var state) = navigation else { return }
        state.close(at: column.index)
        presentWide(state)
    }
}

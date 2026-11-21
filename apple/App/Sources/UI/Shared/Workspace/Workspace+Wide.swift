extension Workspace {
    func selectWide(_ route: Route) {
        guard case .wide(var state) = navigation else { return }
        let previous = mainRoute
        switch route {
        case .cue: return showCue()
        case .session(let session): return openWideSession(session, in: .main)
        case .card, .libraryFile: return present(Overlay(route)!)
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

    func present(_ page: Overlay) {
        if case .card(let id) = page, beside.contains(.card(id)) { return }
        #if os(macOS)
        presses.clearSelection()
        #endif
        if case .wide(var state) = navigation, state.home {
            state.home = false
            navigation = .wide(state)
        }
        overlay = page
    }

    func goHome() {
        guard case .wide(var state) = navigation, !state.home else { return }
        openTask = nil
        state.home = true
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
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
    }

    var railExpanded: Bool {
        get { services.settings.railExpanded }
        set { services.settings.railExpanded = newValue }
    }

    func hideCue(fits: Bool) {
        cueDrawer = false
        if fits, !cueHome { services.settings.cueOpen = false }
    }

    func cueShown(_ sizes: WideMetrics) -> Bool { sizes.cue > 0 || !sizes.cueFits && cueDrawer }

    func toggleCue(_ sizes: WideMetrics) {
        if cueShown(sizes) { hideCue(fits: sizes.cueFits) } else { showCue() }
    }

    func openWideSession(_ session: SessionRoute, in column: Column) {
        guard case .wide(var state) = navigation else { return }
        openTask = nil
        if case .beside = column, state.mainSession == nil, let card = openCard {
            overlay = nil
            state.main = .session(session)
            state.beside = [.card(card)]
        } else if case .beside(let index) = column, let main = state.mainSession, wideRoom > 1 {
            let shown = wideShown, full = 1 + shown >= wideRoom
            if main.id != session.id, !state.beside.contains(.session(session)) {
                let at = index < shown ? index + 1 : full ? shown : shown + 1
                state.place(.session(session), at: at, replacing: index < shown || full, room: wideRoom)
            }
        } else {
            state.beside.removeAll { $0 == .session(session) }
            state.main = .session(session)
        }
        state.home = false
        presentWide(state)
    }

    @discardableResult func drop(_ pane: WideNavigation.Beside, at index: Int, replacing: Bool) -> Bool {
        guard case .wide(let state) = navigation,
              let next = state.dropping(pane, at: index, replacing: replacing, room: wideRoom, covering: openCard) else { return false }
        openTask = nil
        if let card = openCard, next.beside.contains(.card(card)) { overlay = nil }
        presentWide(next)
        return true
    }

    func moveColumn(_ column: Column, by step: Int) -> Bool {
        guard case .wide(var state) = navigation, state.mainSession != nil, let pane = pane(in: column) else { return false }
        let target = column.index + step
        guard target >= 0, target <= wideShown, state.place(pane, at: target, replacing: true, room: wideRoom) else { return false }
        presentWide(state)
        return true
    }

    func pane(in column: Column) -> WideNavigation.Beside? {
        guard case .wide(let state) = navigation, let main = state.mainSession else { return nil }
        switch column {
        case .main: return .session(main)
        case .beside(let index): return state.beside.indices.contains(index) ? state.beside[index] : nil
        }
    }

    func session(in column: Column) -> SessionRoute? {
        if case .session(let route)? = pane(in: column) { route } else { nil }
    }

    private var wideSizes: WideMetrics? { wideFits.map { WideMetrics(width: $0.width, workspace: self) } }

    var wideRoom: Int { wideSizes?.room ?? 2 }

    var wideShown: Int { wideSizes?.beside.count ?? beside.count }

    private func presentWide(_ state: WideNavigation) {
        let previous = mainRoute
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    func closeColumn(_ column: Column) {
        guard case .wide(var state) = navigation else { return }
        if state.mainSession == nil, column == .main {
            state.main = .browse
            state.home = true
        } else {
            state.close(at: column.index)
        }
        presentWide(state)
    }
}

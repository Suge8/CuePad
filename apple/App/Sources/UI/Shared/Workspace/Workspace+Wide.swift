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

    /// 盖一页在主区上（`overlay`）：主区要露着，Cue 铺满时先让到右边。已并排着的灵感不再盖一份（同一条只在一处可改）。
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
        // 窗口宽每次拖窗口都报（`Fits.width`）：只在真要改时写，不然每一帧都惊动读它的视图
        if railDrawer, fits.rail || previous.map({ $0.rail != fits.rail }) == true { railDrawer = false }
        if cueDrawer, fits.cue || previous.map({ $0.cue != fits.cue }) == true { cueDrawer = false }
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

    /// 会话已在主区别的块里时挪过来、不复制。`main` 换掉最左那块（它在右边时那块关掉）；`beside(i)` 在最左已是会话时开在右边第 i 块（`aside` 见它的注释），否则同 `main`。
    func openWideSession(_ session: SessionRoute, in column: Column) {
        guard case .wide(var state) = navigation else { return }
        openTask = nil
        if case .beside = column, state.mainSession == nil, let card = openCard {
            // 看着一条灵感时把会话开在旁边：会话占最左，灵感挪到它右边，接着边聊边看
            overlay = nil
            state.main = .session(session)
            state.beside = [.card(card)]
        } else if case .beside(let index) = column, let main = state.mainSession, wideRoom > 1 {
            let shown = wideShown, full = 1 + shown >= wideRoom
            if main.id != session.id, !state.beside.contains(.session(session)) {
                // 放满了的开在旁边换掉看得见的最右那块（`wideShown`：窗口变窄后藏起的几块还在导航里，不换看不见的）
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

    /// 拖进主区放下（`WideDrop`）、灵感页头的并排钮：`index` 是放下后它在几块里的序号，`replacing` 换掉那一块；规则在 `WideNavigation.dropping`。
    /// 同窗口里拖来的已在主区，挪过去；跨窗口只在这个窗口打开，不改源窗口。放不了的不动、返回假。
    @discardableResult func drop(_ pane: WideNavigation.Beside, at index: Int, replacing: Bool) -> Bool {
        guard case .wide(let state) = navigation,
              let next = state.dropping(pane, at: index, replacing: replacing, room: wideRoom, covering: openCard) else { return false }
        openTask = nil
        if let card = openCard, next.beside.contains(.card(card)) { overlay = nil }
        presentWide(next)
        return true
    }

    /// 栏头的键盘挪（⌘⌥← →）：这一块与左边或右边看得见的那块对调；最左只能是会话，挪不过去的不动、返回假（焦点不跟过去）。
    /// focus 不存到导航；调用方把实际有键盘焦点的那一块传进来。
    func moveColumn(_ column: Column, by step: Int) -> Bool {
        guard case .wide(var state) = navigation, state.mainSession != nil, let pane = pane(in: column) else { return false }
        let target = column.index + step
        guard target >= 0, target <= wideShown, state.place(pane, at: target, replacing: true, room: wideRoom) else { return false }
        presentWide(state)
        return true
    }

    /// 主区第几块放的是什么（最左那块不是会话时为 nil）。
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

    /// 按宽屏的根报来的窗口宽、此刻的导航排一遍（还没排过版时为 nil）。
    private var wideSizes: WideMetrics? { wideFits.map { WideMetrics(width: $0.width, workspace: self) } }

    /// 窗口此刻放得下几块（`WideMetrics.room`）：开在旁边、插进来时多出的挤掉最右那块；只放得下一块时开在旁边就是开在主区。
    var wideRoom: Int { wideSizes?.room ?? 2 }

    /// 右边此刻画出来几块（`WideMetrics.beside`）：窗口变窄后右端藏起的还在 `beside` 里，开在旁边、拖放、键盘挪只认看得见的。
    var wideShown: Int { wideSizes?.beside.count ?? beside.count }

    private func presentWide(_ state: WideNavigation) {
        let previous = mainRoute
        cueDrawer = false
        railDrawer = false
        navigation = .wide(state)
        if mainRoute != previous { willSelect(mainRoute, from: previous) }
    }

    /// 收起一块：最左那块收起时右边第一个会话补上，右边没有会话就回到 Cue（只开一个时键盘的返回走这里）。
    /// 右边的块由各自栏头末端的收起钮收；最左那块是主区此刻的页，换去处靠会话条，键盘的返回才关它。不另存返回来源。
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

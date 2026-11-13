#if os(iOS)
import CueStore
import SwiftUI

/// Cue 的名牌长开着时读屏只读 Cue 那一块：宽屏的名牌只长在 Cue 里，所以其余整块藏起；Cue 那一块里由名牌所在的页藏起旁边的（`FloatingHeader`）。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(ModalHost.self) private var modals: ModalHost?
    @Environment(\.palette) private var palette
    @State private var focus = WideFocus()

    var body: some View {
        let covered = modals?.modal?.inPage == true
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            // 右边那一栏的 Cue 是浮在主区上的一块玻璃（`CuePanel`，同 Mac 的 `MainWindow`）：主区铺到窗口右缘，压在它下面的那一截交给页自己让
            let under = sizes.split || sizes.home ? 0 : sizes.cue
            HStack(spacing: 0) {
                if sizes.railFits { WideRail(width: sizes.rail, sizes: sizes) }
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.home) {
                    destination(workspace.mainRoute, column: .main)
                        .environment(\.headInset, EdgeInsets(top: 0, leading: Chrome.headLead(rail: sizes.rail), bottom: 0, trailing: Spacing.page))
                        .environment(\.underCue, under)
                }
                .frame(width: sizes.leading + under)
                .reachesWindowBottom()
                if sizes.split, let beside = workspace.besideSession {
                    WideColumnHost(slot: .beside, focus: focus, origin: sizes.rail + sizes.leading, width: sizes.main - sizes.leading, shape: sizes.shape) {
                        destination(.session(beside), column: .beside)
                    }
                    .frame(width: sizes.main - sizes.leading)
                    .reachesWindowBottom()
                }
                Spacer(minLength: 0)
            }
            .overlay { if !sizes.home { railChrome(sizes) } }
            .readerHidden(covered)
            // 排在最上：抽屉开着时它与接点按的底盖住浮着的那一排与会话条的抽屉
            .overlay {
                CueDock(sizes: sizes, width: geometry.size.width, focus: focus, bleed: EdgeInsets(top: geometry.safeAreaInsets.top, leading: 0, bottom: 0, trailing: 0)) { cue(fits: $0, home: sizes.home, bottom: geometry.safeAreaInsets.bottom) }
            }
            // Cue 铺满时它那一块伸到窗口左缘（会话条藏起）：浮着的那一排与会话条的抽屉排在它上面，不然点不到（同 Mac 的 `MainWindow`）
            .overlay { if sizes.home { railChrome(sizes).readerHidden(covered) } }
            .reportsWideFits(sizes, to: workspace)
            // 桌面色一处铺满窗口（托管的几块是透明的，`WideColumnController`）：几块的上沿排在状态栏底下，状态栏那一条也要是桌面色
            .background(palette.desk)
        }
        .overlay(alignment: .top) { NoticeBanner().readerHidden(covered) }
        .environment(\.wideWindowID, focus.windowID)
        .onChange(of: covered) { DebugHooks.readerLayers(outsideCue: covered, drawer: workspace.cueDrawer) }
    }

    /// 藏起时顶上那一排原地浮着；放不下时拉出的抽屉里有同一排（同一个位置），抽屉开着就不再浮一份。
    private func railChrome(_ sizes: WideMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            if !workspace.railShown(sizes) { RailTopTools(sizes: sizes, floating: true) }
            if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail, sizes: sizes) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 浮板伸到横条那一截里、离窗口下缘同样一小圈（`bottom` 是横条让出的高）：停在横条上沿的话，板底下露出一条看板。
    /// 板里的页照样让出横条（少掉板自己那一圈），名牌离板的上沿也留一圈。
    private func cue(fits: Bool, home: Bool, bottom: CGFloat) -> some View {
        let inset = fits && !home ? CuePanel.float : 0
        return CuePage().countsAsViewer()
            .environment(\.headerHost, .panel)
            .modifier(KeyboardHold())
            .safeAreaPadding(.top, inset)
            .safeAreaPadding(.bottom, max(0, bottom - inset))
            .clipShape(.rect(cornerRadius: CuePanel.corner(fits: fits, home: home)))
            .cuePanel(fits: fits, home: home)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder private func destination(_ route: Route, column: Workspace.Column) -> some View {
        DestinationColumn(route: route, column: column)
    }
}

private struct DestinationColumn: View {
    let route: Route
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under

    var body: some View {
        // 看板自己让（列滑到浮板下面，`ProgressScreen`）；别的页整页让出
        let board = route == .progress
        VStack(spacing: 0) {
            if case .session(let session) = route { WideSessionHeading(session: session, column: column) }
            if case .project = route {
                WideProjectHeading().frame(maxWidth: .infinity, alignment: .leading).padding(inset).frame(height: Chrome.band)
            }
            NavigationStack(path: Binding<[Route]>(get: { [] }, set: { if let route = $0.last { workspace.show(route) } })) {
                RouteView(route: route)
                    .environment(\.headerHost, route.isSession ? .navigationBar : .panel)
                    .toolbarVisibility(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            .fadesUnderHead(route.isSession)
        }
        .padding(.trailing, board ? 0 : under)
    }
}

private extension Route {
    var isSession: Bool { if case .session = self { true } else { false } }
}

private struct WideSessionHeading: View {
    let session: SessionRoute
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var state: SessionState??
    @State private var taskLink: SessionTaskLink?

    var body: some View {
        let shown = (state ?? nil) ?? session.seed?.session
        WideSessionTitle(title: shown?.title ?? "", project: workspace.catalog?.project(shown?.projectID)?.shownName, column: column)
            .contextMenu {
                if let shown, let taskLink { SessionTaskBindItems(session: shown, link: taskLink) }
            }
            .observing(services.store, id: session.id, into: $state, onError: workspace.fail) { [id = session.id] store in
                try store.sessionPage(SessionQuery(id: id)).items.first?.listed
            }
            .observing(services.store, id: SessionTaskLink.Key(session: shown?.sessionID, project: shown?.projectID), into: $taskLink, onError: workspace.fail) { [shown] store in
                try SessionTaskLink.read(sessionID: shown?.sessionID ?? "", project: shown?.projectID, from: store)
            }
    }
}
#endif

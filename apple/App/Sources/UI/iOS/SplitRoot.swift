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
            HStack(spacing: 0) {
                if sizes.railFits { WideRail(width: sizes.rail, sizes: sizes) }
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading, shape: sizes.shape) {
                    destination(workspace.mainRoute, column: .main)
                        .environment(\.headInset, EdgeInsets(top: 0, leading: Chrome.headLead(rail: sizes.rail), bottom: 0, trailing: Spacing.page))
                }
                .frame(width: sizes.leading)
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
            // 藏起时顶上那一排原地浮着；放不下时拉出的抽屉里有同一排（同一个位置），抽屉开着就不再浮一份
            .overlay(alignment: .topLeading) { if !workspace.railShown(sizes) { RailTopTools(sizes: sizes, floating: true) } }
            .overlay(alignment: .leading) {
                if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail, sizes: sizes) } }
            }
            .readerHidden(covered)
            // 排在最上：抽屉开着时它与接点按的底盖住浮着的那一排与会话条的抽屉
            .overlay {
                CueDock(sizes: sizes, width: geometry.size.width, focus: focus, bleed: EdgeInsets(top: geometry.safeAreaInsets.top, leading: 0, bottom: 0, trailing: 0)) { _ in cue }
            }
            .reportsWideFits(sizes, to: workspace)
            // 桌面色一处铺满窗口（托管的几块是透明的，`WideColumnController`）：几块的上沿排在状态栏底下，状态栏那一条也要是桌面色
            .background(palette.desk)
        }
        .overlay(alignment: .top) { NoticeBanner().readerHidden(covered) }
        .environment(\.wideWindowID, focus.windowID)
        .onChange(of: covered) { DebugHooks.readerLayers(outsideCue: covered, drawer: workspace.cueDrawer) }
    }

    private var cue: some View {
        CuePage().countsAsViewer()
            .environment(\.headerHost, .panel)
            .modifier(KeyboardHold())
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

    var body: some View {
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

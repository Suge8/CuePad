#if os(iOS)
import CueStore
import SwiftUI

/// iPad 宽屏（宽窗）：会话条（`WideRail`，导航只在这一处）、主区（浏览页、辅助页、一个会话或并排两个）、右边一直是 Cue。尺寸与自动收起同 Mac（`WideMetrics`）。
/// 主区与 Cue 的页自己画页顶（`floatingHeader`）；会话页上面是会话的栏头（`WideSessionTitle`），项目页上面一排写项目名与介绍（`WideProjectHeading`，页里不另写）。
/// Cue 钮在会话条顶上那一排（`RailTopTools`）：露着时点了收起，收着时放回；收起的 Cue 仍挂着，只是藏起。
/// 会话条藏起时那一排（侧栏钮、搜索、Cue 钮）原地浮在主区左上角，主区的栏头左边让出它们（`Chrome.headLead`）；放不下时侧栏钮从左缘拉出会话条的抽屉（`RailDrawer`）。
/// 放不下时同一块是窗口右缘的抽屉（同 Mac，`CueDock`，`Workspace.cueDrawer`）：一个窗口只挂这一份 Cue 页，跨过临界宽不重建。
/// Cue 的名牌长开着（原位的模态浮出，`ModalHost`）时读屏只读 Cue 那一块：宽屏的名牌只长在 Cue 里（Cue 不进主区），右栏与抽屉同一块，
/// 所以这里把它以外的（主区、会话条与它的抽屉、浮着的那一排、提示横幅）整块藏起；Cue 那一块里由名牌所在的页藏起旁边的（`FloatingHeader`）。
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
        CuePage().countsAsPiViewer()
            .environment(\.headerHost, .panel)
            .modifier(KeyboardHold())
    }

    @ViewBuilder private func destination(_ route: Route, column: Workspace.Column) -> some View {
        DestinationColumn(route: route, column: column)
    }
}

/// 主区的一边：会话的栏头或项目页那一排（左边让出 `headInset`：会话条藏起时浮在左上角的那一排钮），下面是这一页。
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
            // 会话的栏头是写着字的一排：对话到它下沿淡出，同 Mac（`Bars`）
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
    @State private var state: PiSessionState??

    var body: some View {
        let shown = (state ?? nil) ?? session.seed?.session
        WideSessionTitle(title: shown?.title ?? "", project: workspace.catalog?.project(shown?.projectID)?.shownName, column: column)
            .observing(services.store, id: session.id, into: $state, onError: workspace.fail) { [id = session.id] store in
                try store.piSessionPage(PiSessionQuery(id: id)).items.first?.listed
            }
    }
}
#endif

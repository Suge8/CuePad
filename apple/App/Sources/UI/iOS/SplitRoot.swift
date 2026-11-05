#if os(iOS)
import CueStore
import SwiftUI

/// iPad 宽屏（宽窗）：会话条（`WideRail`，导航只在这一处）、主区（浏览页、辅助页、一个会话或并排两个）、右边一直是 Cue。尺寸与自动收起同 Mac（`WideMetrics`）。
/// 主区与 Cue 的页自己画页顶（`floatingHeader`）；会话页上面是会话的栏头（`WideSessionTitle`），项目页上面一排写项目名与介绍（`WideProjectHeading`，页里不另写）。
/// Cue 钮在会话条顶上那一排（`RailTopTools`）：露着时点了收起，收着时放回；收起的 Cue 仍挂着，只是藏起。
/// 会话条藏起时那一排（侧栏钮、搜索、Cue 钮）原地浮在主区左上角，主区的栏头左边让出它们（`Chrome.headLead`）；放不下时侧栏钮从左缘拉出会话条的抽屉（`RailDrawer`）。
/// 放不下时 Cue 住进窗口右缘的抽屉（同 Mac 的 `MainWindow`，`Workspace.cueDrawer`）：一个时刻只挂一份 Cue 页，跨过临界宽时换处、重建一次。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var focus = WideFocus()

    var body: some View {
        @Bindable var workspace = workspace
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            HStack(spacing: 0) {
                if sizes.railFits { WideRail(width: sizes.rail, sizes: sizes) }
                WideColumnHost(slot: .main, focus: focus) {
                    destination(workspace.mainRoute, column: .main)
                        .environment(\.headInset, EdgeInsets(top: 0, leading: Chrome.headLead(rail: sizes.rail), bottom: 0, trailing: Spacing.page))
                }
                .frame(width: sizes.leading)
                if sizes.split, let beside = workspace.besideSession {
                    WideColumnHost(slot: .beside, focus: focus) { destination(.session(beside), column: .beside) }
                        .frame(width: sizes.main - sizes.leading)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                if sizes.cueFits {
                    WideColumnHost(slot: .cue, focus: focus, hidden: sizes.cue == 0) { cue.environment(\.pageActive, sizes.cue > 0) }
                        .frame(width: WideMetrics.cue)
                } else {
                    Color.clear.frame(width: 0).drawer(isPresented: $workspace.cueDrawer) { cue.frame(width: WideMetrics.cue) }
                }
            }
            // 藏起时顶上那一排原地浮着；放不下时拉出的抽屉里有同一排（同一个位置），抽屉开着就不再浮一份
            .overlay(alignment: .topLeading) { if !workspace.railShown(sizes) { RailTopTools(sizes: sizes, floating: true) } }
            .overlay(alignment: .leading) {
                if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail, sizes: sizes) } }
            }
            // 桌面色一处铺满窗口（托管的几块是透明的，`WideColumnController`）：几块只排在安全区里，状态栏那一条与底下横条那一截也要是桌面色
            .background(palette.desk)
        }
        .overlay(alignment: .top) { NoticeBanner() }
        .environment(\.wideWindowID, focus.windowID)
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

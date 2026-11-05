#if os(iOS)
import CueStore
import SwiftUI

/// iPad 宽屏（宽窗）：会话条（`WideRail`，导航只在这一处）、主区（浏览页、辅助页、一个会话或并排两个）、右边一直是 Cue。尺寸与自动收起同 Mac（`WideMetrics`）。
/// 主区与 Cue 的页自己画页顶（`floatingHeader`）；会话页上面是会话的栏头（`WideSessionTitle`），项目页上面一排写项目名与介绍（`WideProjectHeading`，页里不另写）。
/// Cue 钮一直在会话条顶上那一排（`CueButton`）：露着时点了收起，收着时放回；收起的 Cue 仍挂着，只是藏起。
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
                WideRail(width: sizes.rail, cue: (sizes.cueFits, workspace.cueShown(sizes)))
                WideColumnHost(slot: .main, focus: focus) { destination(workspace.mainRoute, column: .main) }
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
            // 桌面色一处铺满窗口（托管的几块是透明的，`WideColumnController`）：几块只排在安全区里，状态栏那一条与底下横条那一截也要是桌面色
            .background(palette.desk)
        }
        .railTips()
        .overlay(alignment: .top) { NoticeBanner() }
        .environment(\.wideWindowID, focus.windowID)
    }

    private var cue: some View {
        CuePage().countsAsPiViewer()
            .environment(\.headerHost, .panel)
            .modifier(KeyboardHold())
    }

    @ViewBuilder private func destination(_ route: Route, column: Workspace.Column) -> some View {
        VStack(spacing: 0) {
            if case .session(let session) = route { WideSessionHeading(session: session, column: column) }
            if case .project = route {
                WideProjectHeading().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Spacing.page).frame(height: Chrome.band)
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

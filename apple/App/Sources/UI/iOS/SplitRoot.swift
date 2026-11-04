#if os(iOS)
import CueStore
import SwiftUI

/// iPad 宽屏（宽窗）：会话条（`WideRail`，导航只在这一处）、主区（浏览页、辅助页、一个会话或并排两个）、右边一直是 Cue。尺寸与自动收起同 Mac（`WideMetrics`）。
/// 主区与 Cue 的页自己画页顶（`floatingHeader`）；会话页上面是会话的栏头（`WideSessionTitle`），项目页上面一排写项目名与介绍（`WideProjectHeading`，页里不另写）。
/// Cue 钮一直在会话条顶上那一排（`CueButton`）：露着时点了收起，收着时放回（放不下时从右边浮出、盖在主区上）；收起的 Cue 仍挂着，只是藏起。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var focus = WideFocus()

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let floats = sizes.cue == 0 && !sizes.cueFits && workspace.cueFloats
            let shown = sizes.cue > 0 || floats
            HStack(spacing: 0) {
                WideRail(width: sizes.rail, cue: (sizes.cueFits, shown))
                WideColumnHost(slot: .main, focus: focus) {
                    destination(workspace.mainRoute, column: .main)
                        .environment(\.boardFits, sizes.leading >= WideMetrics.board)
                }
                .frame(width: sizes.leading)
                if sizes.split, let beside = workspace.besideSession {
                    WideColumnHost(slot: .beside, focus: focus) { destination(.session(beside), column: .beside) }
                        .frame(width: sizes.main - sizes.leading)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                WideColumnHost(slot: .cue, focus: focus, hidden: !shown) {
                    CuePage().countsAsPiViewer()
                        .environment(\.headerHost, .panel)
                        .environment(\.pageActive, shown)
                        .modifier(KeyboardHold())
                }
                .frame(width: WideMetrics.cue)
                .background { if floats { palette.desk.elevation(.panel) } }
            }
        }
        .railTips()
        .overlay(alignment: .top) { NoticeBanner() }
        .environment(\.wideWindowID, focus.windowID)
    }

    @ViewBuilder private func destination(_ route: Route, column: Workspace.Column) -> some View {
        VStack(spacing: 0) {
            if case .session(let session) = route { WideSessionHeading(session: session, column: column) }
            if case .project = route {
                WideProjectHeading().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: Chrome.band)
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

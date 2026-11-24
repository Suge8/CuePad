#if os(iOS)
import CueStore
import SwiftUI

struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(ModalHost.self) private var modals: ModalHost?
    @Environment(\.palette) private var palette
    @State private var focus = WideFocus()

    var body: some View {
        let covered = modals?.modal?.inPage == true
        WideShell(focus: focus, covered: covered) { sizes, index in
            EdgeInsets(top: 0, leading: index == 0 ? Chrome.headLead(rail: sizes.rail) : Spacing.page, bottom: 0, trailing: Spacing.page)
        } rail: { sizes, width in
            WideRail(width: width, sizes: sizes)
        } tools: { sizes in
            if !sizes.fill, !workspace.railShown(sizes) { RailTopTools(sizes: sizes, floating: true) }
        } cue: { fits, geometry in
            cue(fits: fits, bottom: geometry.safeAreaInsets.bottom)
        }
        .background(palette.desk)
        .overlay(alignment: .top) { NoticeBanner().readerHidden(covered) }
        .environment(\.wideWindowID, focus.windowID)
        .onChange(of: covered) { DebugHooks.readerLayers(outsideCue: covered, drawer: workspace.cueDrawer) }
    }

    private func cue(fits: Bool, bottom: CGFloat) -> some View {
        let inset = fits ? CuePanel.float : 0
        return CuePage()
            .environment(\.headerHost, .panel)
            .modifier(KeyboardHold())
            .safeAreaPadding(.top, inset)
            .safeAreaPadding(.bottom, max(0, bottom - inset))
            .clipShape(.rect(cornerRadius: CuePanel.corner(fits: fits)))
            .cuePanel(fits: fits)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// 宽屏一块里的内容（`PageLayer`、`SessionLayer`、`CoverLayer` 摆它）：页与会话在各自的导航栈里，页里的链接经它交给 `Workspace.show`。
struct RouteBody: View {
    let route: Route?
    let column: Workspace.Column
    @Environment(\.underCue) private var under
    @Environment(\.palette) private var palette

    var body: some View {
        switch route {
        case nil: EmptyView()
        case .libraryFile(let file)?: RouteView(route: .libraryFile(file)).environment(\.headerHost, .column).background(palette.desk)
        case let route?: RouteStack(route: route, column: column).padding(.trailing, route == .progress ? 0 : under)
        }
    }
}

private struct RouteStack: View {
    let route: Route
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationStack(path: Binding<[Route]>(get: { [] }, set: { if let route = $0.last { workspace.show(route) } })) {
            RouteView(route: route, column: column)
                .environment(\.headerHost, route == .search ? .panel : .column)
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}
#endif

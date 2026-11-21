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
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let under = sizes.split || sizes.home ? 0 : sizes.cue
            HStack(spacing: 0) {
                if sizes.railFits { WideRail(width: sizes.rail, sizes: sizes) }
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.home || sizes.fill, under: under, spans: sizes.spans) {
                    destination(workspace.mainRoute, column: .main)
                        .environment(\.headInset, EdgeInsets(top: 0, leading: Chrome.headLead(rail: sizes.rail), bottom: 0, trailing: Spacing.page))
                        .environment(\.underCue, under)
                }
                .frame(width: sizes.leading + under)
                .reachesWindowBottom()
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<WideNavigation.maxPanes - 1, id: \.self) { beside($0, sizes, window: geometry.size.width) }
                }
            }
            .overlay { if !sizes.fill { ForEach(0..<sizes.widths.count - 1, id: \.self) { BesideDivider(sizes: sizes, index: $0) } } }
            .overlay { WideDropFeedback(window: geometry.size.width) }
            .overlay { if !sizes.home, !sizes.fill { railChrome(sizes) } }
            .readerHidden(covered)
            .overlay {
                CueDock(sizes: sizes, width: geometry.size.width, focus: focus, bleed: EdgeInsets(top: geometry.safeAreaInsets.top, leading: 0, bottom: 0, trailing: 0)) { cue(fits: $0, home: sizes.home, bottom: geometry.safeAreaInsets.bottom) }
            }
            .overlay { if sizes.home { railChrome(sizes).readerHidden(covered) } }
            .reportsWideFits(sizes, to: workspace)
            .background(palette.desk)
        }
        .overlay(alignment: .top) { NoticeBanner().readerHidden(covered) }
        .environment(\.wideWindowID, focus.windowID)
        .onChange(of: covered) { DebugHooks.readerLayers(outsideCue: covered, drawer: workspace.cueDrawer) }
    }

    private func beside(_ index: Int, _ sizes: WideMetrics, window: CGFloat) -> some View {
        let origin = sizes.origin(index + 1, window: window), width = sizes.width(index + 1)
        return WideColumnHost(slot: .beside(index), focus: focus, origin: origin, width: width, shape: sizes.shape, hidden: origin >= window, spans: sizes.spans) {
            BesideColumn(index: index) { destination(.session($0), column: .beside(index)) } card: { IdeaPane(cardID: $0, column: .beside(index)) }
        }
        .frame(width: width)
        .padding(.leading, origin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .reachesWindowBottom()
    }

    private func railChrome(_ sizes: WideMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            if !workspace.railShown(sizes) { RailTopTools(sizes: sizes, floating: true) }
            if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail, sizes: sizes) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cue(fits: Bool, home: Bool, bottom: CGFloat) -> some View {
        let inset = fits && !home ? CuePanel.float : 0
        return CuePage()
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
    @Environment(\.palette) private var palette

    var body: some View {
        let overlay = column == .main ? workspace.overlay : nil
        let board = route == .progress && overlay == nil
        let headed = overlay != nil || !route.isSession && route != .search
        ZStack(alignment: .top) {
            NavigationStack(path: Binding<[Route]>(get: { [] }, set: { if let route = $0.last { workspace.show(route) } })) {
                RouteView(route: route, column: column)
                    .environment(\.headerHost, route == .search ? .panel : .column)
                    .toolbarVisibility(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { RouteView(route: $0) }
            }
            if let overlay {
                RouteView(route: overlay.route)
                    .environment(\.headerHost, .panel)
                    .background(palette.desk)
                    .id(overlay)
                    .transition(.opacity)
            }
            if headed { WideColumnHead().padding(inset).frame(height: Chrome.band) }
        }
        .animation(Motion.fade, value: overlay)
        .padding(.trailing, board ? 0 : under)
    }
}

private extension Route {
    var isSession: Bool { if case .session = self { true } else { false } }
}
#endif

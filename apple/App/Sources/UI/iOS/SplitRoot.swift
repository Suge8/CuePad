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
            let under = sizes.split ? 0 : sizes.cue
            HStack(spacing: 0) {
                if sizes.railFits { WideRail(width: sizes.rail, sizes: sizes) }
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.fill, under: under, spans: sizes.spans) {
                    PaneColumn(index: 0)
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
            .overlay { if !sizes.fill { railChrome(sizes) } }
            .readerHidden(covered)
            .overlay {
                CueDock(sizes: sizes, width: geometry.size.width, focus: focus, bleed: EdgeInsets(top: geometry.safeAreaInsets.top, leading: 0, bottom: 0, trailing: 0)) { cue(fits: $0, bottom: geometry.safeAreaInsets.bottom) }
            }
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
            PaneColumn(index: index + 1)
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

/// 这一排里的那一页连同它的栏头。
struct PageLayer: View {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under

    var body: some View {
        if let page = workspace.pageRoute {
            ZStack(alignment: .top) {
                RouteStack(route: page, column: column)
                if page != .search, workspace.overlay == nil { WideColumnHead(column: column).padding(inset).frame(height: Chrome.band) }
            }
            .padding(.trailing, page == .progress ? 0 : under)
        }
    }
}

struct SessionLayer: View {
    let route: SessionRoute
    let column: Workspace.Column
    @Environment(\.underCue) private var under

    var body: some View {
        RouteStack(route: .session(route), column: column).padding(.trailing, under)
    }
}

/// 点开盖在页上的那一层：灵感、规则文件。
struct CoverLayer: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.underCue) private var under
    @Environment(\.palette) private var palette

    var body: some View {
        let overlay = workspace.overlay
        ZStack(alignment: .top) {
            switch overlay {
            case .card(let id)?:
                IdeaPane(cardID: id, covers: true) { workspace.close(.card(id)) }.id(id).transition(.opacity)
            case .library(let file)?:
                RouteView(route: .libraryFile(file)).environment(\.headerHost, .column).background(palette.desk).id(file).transition(.opacity)
                LibraryFileHead(file: file).transition(.opacity)
            case nil: EmptyView()
            }
        }
        .animation(Motion.fade, value: overlay)
        .padding(.trailing, under)
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

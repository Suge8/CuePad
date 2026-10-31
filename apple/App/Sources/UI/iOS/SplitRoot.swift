#if os(iOS)
import CueStore
import SwiftUI

struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @State private var focus = WideFocus()

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            HStack(spacing: 0) {
                WideRail(width: sizes.rail)
                WideColumnHost(column: .main, focus: focus) {
                    VStack(spacing: 0) {
                        HStack {
                            SidebarToggle(shown: workspace.sidebarOpen)
                            WidePlaces()
                            Spacer()
                        }.padding(.horizontal, 16).frame(height: 44)
                        destination(workspace.mainRoute, column: .main)
                    }
                    .modifier(WideDrop(column: .main))
                }.frame(width: sizes.main)
                WideColumnHost(column: .side, focus: focus) {
                    destination(workspace.sideSession.map(Route.session) ?? .cue, column: .side)
                        .modifier(WideDrop(column: .side))
                }.frame(width: sizes.side)
            }
        }
        .overlay(alignment: .top) { NoticeBanner() }
    }

    @ViewBuilder private func destination(_ route: Route, column: Workspace.Column) -> some View {
        if route == .cue {
            CuePage(inPanel: true).countsAsPiViewer()
                .environment(\.headerHost, .panel)
                .modifier(KeyboardHold())
        } else {
            VStack(spacing: 0) {
                if case .session(let session) = route { WideSessionHeading(session: session, column: column) }
                NavigationStack(path: Binding<[Route]>(get: { [] }, set: { if let route = $0.last { workspace.show(route) } })) {
                    RouteView(route: route)
                        .environment(\.headerHost, route.isSession ? .navigationBar : .panel)
                        .toolbarVisibility(.hidden, for: .navigationBar)
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
            }
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
    @State private var title: String?

    var body: some View {
        WideSessionTitle(title: title ?? session.seed?.session?.title ?? "", column: column)
            .observing(services.store, id: session.id, into: $title, onError: workspace.fail) { [id = session.id] store in
                try store.piSessionPage(PiSessionQuery(id: id)).items.first?.state.title ?? ""
            }
    }
}

/// 共享页头沿用的开合入口；shown 只表达调用方读到的选择，不另存开合值。
struct SidebarToggle: View {
    let shown: Bool
    @Environment(Workspace.self) private var workspace
    var body: some View {
        Button("侧栏", icon: .sidebar) { workspace.toggleSidebar() }.labelStyle(.iconOnly)
    }
}
#endif

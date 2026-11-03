#if os(iOS)
import CueStore
import SwiftUI

/// Cue 为根的唯一导航栈；侧栏只是根上的覆盖层。推入页和系统返回都绑定 Workspace.path，不另存返回来源。
struct NarrowRoot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationStack(path: Binding(get: { workspace.path }, set: workspace.setNarrowPath)) {
            NarrowHome()
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

private struct NarrowHome: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slide = NarrowSlide()

    var body: some View {
        GeometryReader { geometry in
            let open = workspace.sidebarOpen
            ZStack {
                NarrowCue()
                    .modifier(NarrowPlacement(slide: slide, width: geometry.size.width, sidebar: false, open: open))
                    .environment(\.pageActive, !open && workspace.path.isEmpty)
                NarrowSidebar()
                    .modifier(NarrowPlacement(slide: slide, width: geometry.size.width, sidebar: true, open: open))
                    .environment(\.pageActive, open && workspace.path.isEmpty)
            }
            .contentShape(.rect)
            .gesture(NarrowPan(slide: slide, workspace: workspace, reduceMotion: reduceMotion))
        }
        .onChange(of: workspace.sidebarOpen, initial: true) { old, open in
            slide.set(open: open, reduceMotion: reduceMotion)
            // 换了一层给读屏：等这一帧把藏起的那层交出去再报，焦点才落到新的一层，不留在藏起的钮上
            if old != open { Task { await NextFrame.drawn(); AccessibilityNotification.ScreenChanged(nil).post() } }
        }
        .background { NarrowKeyboard(sidebarOpen: workspace.sidebarOpen) }
    }
}

private struct NarrowCue: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        RouteView(route: .cue)
            .environment(\.headerHost, .page(search: nil))
            .background(palette.desk.ignoresSafeArea())
            .overlay(alignment: .topLeading) {
                Button("侧栏", icon: .sidebar) { workspace.toggleSidebar() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .frame(height: CueHeader.height)
                    .padding(.leading, FloatingHeaderLayout.margin)
                    .accessibilityIdentifier("narrow-sidebar")
            }
            .overlay(alignment: .leading) {
                SessionRail(data: workspace.services.liveSessions.rail, form: .phone, pulse: workspace.pulse) { session, _ in
                    workspace.openSession(session.id, sessionID: session.sessionID)
                }
                .padding(.top, CueHeader.height + Bars.contentGap)
                .padding(.bottom, ComposerMetrics.slot + 16)
            }
    }
}

private struct NarrowSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var mounted: Set<NavigationPane> = []

    var body: some View {
        let pane = workspace.navigationPane
        ZStack {
            if mounted.contains(.projects) || pane == .projects {
                page(.shelf, pane: .projects, search: .field)
            }
            if mounted.contains(.progress) || pane == .progress {
                page(.progress, pane: .progress, search: .button)
            }
        }
        .safeAreaPadding(.top, FloatingHeaderLayout.height + Bars.contentGap)
        .overlay(alignment: .top) { switcher.padding(.horizontal, FloatingHeaderLayout.margin) }
        .background(palette.desk.ignoresSafeArea())
        .onChange(of: pane, initial: true) { mounted.insert(pane) }
    }

    private func page(_ route: Route, pane: NavigationPane, search: HeaderSearch) -> some View {
        let shown = workspace.navigationPane == pane
        return RouteView(route: route)
            .environment(\.headerHost, .page(search: search))
            .environment(\.pagePrefetch, true)
            .environment(\.pageActive, shown && workspace.sidebarOpen && workspace.path.isEmpty)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .readerHidden(!shown)
    }

    private var switcher: some View {
        HStack(spacing: 8) {
            PaneSegment(
                items: [.init(value: NavigationPane.projects, title: "项目", icon: .projects), .init(value: .progress, title: "进展", icon: .task)],
                selection: workspace.navigationPane, select: workspace.selectPane)
                .fixedSize()
                .frame(height: FloatingHeaderLayout.height - PaneMetrics.inset * 2)
                .padding(PaneMetrics.inset)
                .glass(in: .capsule, interactive: true)
            Spacer(minLength: 0)
            Button { workspace.select(.cue) } label: {
                CueAvatar(workspace.cue.beat, size: .row)
                    .relaySpot(cue: .entry)
                    .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
            }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .accessibilityLabel(workspace.cue.name)
            .accessibilityIdentifier("narrow-cue")
        }
        .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }
}

/// 位移的读数只影响最外面的两层；两页正文不读取每帧进度。读屏只给开合值指着的那层，不随拖动与动画中途变。
private struct NarrowPlacement: ViewModifier {
    let slide: NarrowSlide
    let width: CGFloat
    let sidebar: Bool
    let open: Bool

    func body(content: Content) -> some View {
        let progress = slide.progress
        content
            .offset(x: sidebar ? (progress - 1) * width : progress * width * 0.3)
            .opacity((sidebar ? progress > 0 : progress < 1) ? 1 : 0)
            .allowsHitTesting(sidebar ? progress == 1 : progress == 0)
            .readerHidden(sidebar != open)
    }
}
#endif

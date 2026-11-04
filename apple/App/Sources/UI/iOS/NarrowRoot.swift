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

/// Cue 页与左边常驻的会话条（最底下是"更早"那一格）；名牌长开 Cue 的面板时会话条让开（面板盖住这一屏，`CuePanelOpen`）。
private struct NarrowCue: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var panelOpen = false

    var body: some View {
        RouteView(route: .cue)
            .environment(\.headerHost, .page)
            .background(palette.desk.ignoresSafeArea())
            .onPreferenceChange(CuePanelOpen.self) { panelOpen = $0 }
            .overlay(alignment: .leading) {
                SessionRail(data: workspace.services.liveSessions.rail, form: .phone, pulse: workspace.pulse) { session, _ in
                    workspace.openSession(session.id, sessionID: session.sessionID)
                }
                // 已结束的会话：会话条最底下一格（`EarlierTile`）
                .safeAreaInset(edge: .bottom, spacing: 8) { EarlierTile() }
                .padding(.top, CueHeader.height + Bars.contentGap)
                .padding(.bottom, ComposerMetrics.slot + 16)
                .opacity(panelOpen ? 0 : 1)
                .allowsHitTesting(!panelOpen)
                .readerHidden(panelOpen)
                .animation(Motion.fade, value: panelOpen)
            }
    }
}

/// 侧栏：项目、进展两段叠着、只换看得见的那段；顶上一排是侧栏的（`NarrowSidebarBar`），两段只让出一排的高（`HeaderHost.sidebar`）。
private struct NarrowSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var mounted: Set<NavigationPane> = []

    var body: some View {
        let pane = workspace.navigationPane
        ZStack {
            if mounted.contains(.projects) || pane == .projects {
                page(.shelf, pane: .projects)
            }
            if mounted.contains(.progress) || pane == .progress {
                page(.progress, pane: .progress)
            }
        }
        .overlay(alignment: .top) { NarrowSidebarBar() }
        .background(palette.desk.ignoresSafeArea())
        .onChange(of: pane, initial: true) { mounted.insert(pane) }
    }

    private func page(_ route: Route, pane: NavigationPane) -> some View {
        let shown = workspace.navigationPane == pane
        return RouteView(route: route)
            .environment(\.headerHost, .sidebar)
            .environment(\.pagePrefetch, true)
            .environment(\.pageActive, shown && workspace.sidebarOpen && workspace.path.isEmpty)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .readerHidden(!shown)
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

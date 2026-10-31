#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口的主区与右栏分别呈现导航去处，编辑页与文件页盖在主区上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette

    @State private var focus = WideFocus()

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            HStack(spacing: 0) {
                WideRail(width: sizes.rail)
                    .safeAreaInset(edge: .bottom, spacing: 0) { WideRailTools(wide: sizes.rail == SessionRail.Form.wide.width) }
                WideColumnHost(column: .main, focus: focus, rail: sizes.rail, origin: sizes.rail) {
                    main
                }
                .frame(width: sizes.main)
                WideColumnHost(column: .side, focus: focus, rail: sizes.rail, origin: sizes.rail + sizes.main) {
                    side
                }
                .frame(width: sizes.side)
            }
        }
        .previewPresenter(Bindable(workspace).preview, reply: nil)
        .background(palette.desk)
        .background { WindowPanels(workspace: workspace) }
        .background { TaskBubbleSlot() }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { ToolbarItem(placement: .navigation) { SidebarToggle() } }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .panelHost()
        .environment(workspace)
    }

    private var main: some View {
        VStack(spacing: 0) {
            HStack {
                WidePlaces()
                Spacer(minLength: 8)
                CloseButton()
                if workspace.overlay != nil { OverlayTitle() }
                if workspace.mainRoute == .library { LibraryPanesSlot(); LibraryHelpSlot() }
                SyncAlertSlot()
                SearchSlot()
                if case .session = workspace.mainRoute {} else { PageMenuSlot() }
            }
            .padding(.horizontal, 16).frame(height: 44)
            ZStack {
                CatalogGate { PageStack() }
                EditorLayer().zIndex(1)
                LibraryFileLayer().zIndex(1)
            }
            .overlay(alignment: .bottom) { CaptureSlot() }
        }
    }

    @ViewBuilder private var side: some View {
        CatalogGate {
            if let session = workspace.sideSession, let id = session.sessionID {
                SessionPage(sessionID: id, column: .side).id(id)
            } else {
                VStack(spacing: 0) {
                    HStack { CueTitle(); Spacer(); CueListSlots() }.padding(.horizontal, 16).frame(height: 44)
                    CuePage()
                }
            }
        }
    }
}

/// 本窗口的浮层与确认框（都经 `panel`）。单独一个视图读它们的开合：主窗口的视图体读了，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct WindowPanels: View {
    @Bindable var workspace: Workspace
    @State private var searchScope = SearchScope.cards
    /// ⌘K 面板启动后空闲时（`Prewarm` 同一时机）就挂上，之后一直挂着（`keptPanel`）。
    @State private var mountsPalette = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            // ⌘K 每天用很多次：直接出现、直接消失，不做动画
            .keptPanel(isPresented: $workspace.searching, mounted: mountsPalette) { SearchPalette(scope: $searchScope) }
            .onChange(of: workspace.searching) { if !$1 { searchScope = .cards } else { mountsPalette = true } }
            .task(id: workspace.isLibraryReady) {
                guard workspace.isLibraryReady else { return }
                guard (try? await Task.sleep(for: Prewarm.delay)) != nil else { return }
                mountsPalette = true
            }
            .panel(item: $workspace.projectForm) { ProjectForm($0) }
            .panel(isPresented: $workspace.showsSetup) { SetupPanel() }
            .sessionAsks(workspace)
    }
}

private struct EditorLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, let id = workspace.presses.presented {
            CardEditorPage(cardID: id).id(id)
        }
    }
}

/// 底部输入条：盖着一页（`Workspace.overlay`；灵感的编辑页含淡出途中）时不显示，底栏只有一套，先退后进；⌘K 打开时只是藏起来（不卸下），关掉面板的同一帧就回来。
/// 只在项目页与归档放：回收站、进展页与会话页不是记灵感的地方（进展页的主操作是新任务、新会话，会话页有回复框），它只会压住列表最后几行。
private struct CaptureSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let bare = workspace.isLibraryReady && workspace.overlay == nil && workspace.presses.presented == nil
        if bare, workspace.presses.isSelecting {
            SelectionBar().padding(.bottom, 16).transition(.opacity)
        } else if bare, workspace.mainRoute.takesCapture {
            let searching = workspace.searching
            CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .animation(nil, value: searching)
                .transition(.opacity.animation(Motion.yield))
        }
    }
}

private extension Route {
    /// 底部输入栏放不放（规则在 `CaptureSlot`）。
    var takesCapture: Bool {
        switch self {
        case .project, .archive: true
        default: false
        }
    }
}

extension Workspace {
    /// ⌥⌘N（"文件 › 新会话"）：去进展页的会话段、弹出新会话的表单（表单只有这一个出处）。
    func newSession() {
        showSessions()
        showsNewSession = true
    }
}

/// 窗口级快捷键：⌘1–9 切项目。⌘N 记一条灵感、⌥⌘N 新会话、⌘K 搜索、⌘⇧T 进展页、⌃⌘S 侧栏与设置（⌘,）在主菜单，Esc 关浮层在 `PanelHost`。
/// ⌘1–9 的唯一处理者在这里：工具栏的项目切换菜单收起时不响应其菜单项的快捷键（实测），菜单里的 ⌘ 只是提示。
private struct WorkspaceShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            ForEach(Array(1...9).prefix(workspace.catalog?.projects.count ?? 0), id: \.self) { number in
                Button("项目 \(number)") { workspace.showProject(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

}
#endif

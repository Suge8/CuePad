#if os(macOS)
import CueStore
import SwiftUI

/// 资料库读不出时整窗只有一张"读不出资料库"的卡（`CatalogGate` 挂在三栏外面）：每栏各放一张就是一屏两三张一样的卡；会话条也藏起，一屏只留重试这一个焦点。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette

    @State private var focus = WideFocus()

    var body: some View {
        CatalogGate { columns }
        .ignoresSafeArea(.container, edges: .top)
        .previewPresenter(Bindable(workspace).preview, reply: nil)
        .background(palette.desk)
        .background { WindowPanels(workspace: workspace) }
        .background { TaskBubbleSlot() }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .overlay { NoticeView() }
        .followsUndo(workspace)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .panelHost()
        .environment(workspace)
    }

    private var columns: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let trail = sizes.cue == 0 ? CueButton.reserve : Spacing.page
            // 右边那一栏的 Cue 是浮在主区上的一块玻璃（`CueColumn`）：主区铺到窗口右缘、压在它下面的那一截交给页自己让（`underCue`）
            let under = sizes.split || sizes.home ? 0 : sizes.cue
            HStack(spacing: 0) {
                // 放不下时也挂着（宽 0、不放循环动效、订阅暂停）：窗口拖窄跨过临界宽的那一下主区从它上面滑过去，露出的是它本身
                WideRail(width: sizes.rail)
                // Cue 铺满时主区让出去（宽 0）、页留着不拆，订阅暂停
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.home) {
                    MainColumn().environment(\.headInset, Self.inset(leading: Chrome.headLead(rail: sizes.rail), trailing: sizes.split ? Spacing.page : trail))
                        .environment(\.pageActive, !sizes.home)
                        .environment(\.underCue, under)
                }
                .frame(width: sizes.leading + under)
                if sizes.split {
                    WideColumnHost(slot: .beside, focus: focus, origin: sizes.rail + sizes.leading, width: sizes.main - sizes.leading, shape: sizes.shape) {
                        BesideColumn().environment(\.headInset, Self.inset(trailing: trail))
                    }
                    .frame(width: sizes.main - sizes.leading)
                }
                Spacer(minLength: 0)
            }
            .overlay { if !sizes.home { railChrome(sizes) } }
            .reportsWideFits(sizes, to: workspace)
            .overlay(alignment: .topTrailing) {
                if !workspace.cueShown(sizes) { CueButton(fits: sizes.cueFits).padding(.trailing, Spacing.page).frame(height: Chrome.band) }
            }
            // 排在最上：抽屉开着时它与接点按的底盖住会话条、开合钮与别的抽屉
            .overlay { CueDock(sizes: sizes, width: geometry.size.width, focus: focus) { CueColumn(fits: $0, home: sizes.home, lead: Chrome.headLead(rail: sizes.rail)) } }
            // Cue 铺满时它那一块伸到窗口左缘（会话条藏起）：开合钮与会话条的抽屉排在它上面，不然点不到
            .overlay { if sizes.home { railChrome(sizes) } }
        }
    }

    private func railChrome(_ sizes: WideMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail) } }
            SidebarToggle(sizes: sizes)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func inset(leading: CGFloat = Spacing.page, trailing: CGFloat) -> EdgeInsets {
        EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
    }
}

/// 本窗口的浮层与确认框（都经 `panel`）。单独一个视图读它们的开合：主窗口的视图体读了，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct WindowPanels: View {
    @Bindable var workspace: Workspace
    @State private var searchScope = SearchScope.cards
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
            .modifier(NewSessionPanel())
            .panel(isPresented: $workspace.showsSetup) { SetupPanel() }
            .sessionAsks(workspace)
    }
}

struct EditorLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, let id = workspace.presses.presented {
            CardEditorPage(cardID: id).id(id)
        }
    }
}

/// 只在项目页与归档放：回收站、进展页与会话页不是记灵感的地方（进展页的主操作是新任务、新会话，会话页有回复框），它只会压住列表最后几行。
struct CaptureSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let bare = workspace.isLibraryReady && workspace.overlay == nil && workspace.presses.presented == nil
        if bare, workspace.presses.isSelecting {
            SelectionBar().padding(.bottom, Spacing.block).transition(.opacity)
        } else if bare, workspace.mainRoute.takesCapture {
            let searching = workspace.searching
            CaptureBar(project: workspace.currentProject).padding(.bottom, Spacing.block)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .animation(nil, value: searching)
                .transition(.opacity.animation(Motion.yield))
        }
    }
}

private extension Route {
    var takesCapture: Bool {
        switch self {
        case .project, .archive: true
        default: false
        }
    }
}

/// ⌘1–9 切项目的唯一处理者；别的快捷键在主菜单，Esc 关浮层在 `PanelHost`。
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

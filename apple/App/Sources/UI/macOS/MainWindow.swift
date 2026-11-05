#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：左栏（会话条，`WideRail`，导航只在这一处）、主区（浏览页、辅助页、一个会话或并排两个，`MainColumn`）、右边一直是 Cue（`CueColumn`）。
/// 三栏各自的栏头都排在窗口最顶那一排（红绿灯那一排，`Chrome.band`），同一基线；窗口工具栏只留一条空的，给这一排定高、把红绿灯放在它中线上。
/// 尺寸与自动收起只在 `WideMetrics`。会话条的开合钮钉在红绿灯右边（`SidebarToggle`），会话条藏起时它在主区那一段的最顶一排上，主区栏头左边让出它（`Chrome.headLead`）；
/// 会话条放不下时开合钮从左缘拉出它的抽屉（`RailDrawer`，开合钮压在抽屉之上、位置不动）。Cue 收起后右上一颗 Cue 钮（`CueButton`），它压在最右那一块的栏头右端，那一块的栏头让出它（`headInset`）。
/// 收起的 Cue 仍挂着（对话、滚动位置都在），只是藏起。放不下时它住进窗口右缘的抽屉（`drawer`，`Workspace.cueDrawer`），点 Cue 钮拉出、盖在主区上，
/// 开着时右上不再画 Cue 钮；一个时刻只挂一份 Cue 页，窗口跨过放得下的临界宽时换到另一处、重建一次。
/// 资料库读不出时整窗只有一张"读不出资料库"的卡（`CatalogGate` 挂在三栏外面，同启动时打不开库、同 iOS 的整窗）：三栏都读它，每栏各放一张就是一屏两三张一样的卡；
/// 会话条也藏起——点进去的哪一页都读不出，一屏只留重试这一个焦点。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette

    @State private var focus = WideFocus()

    var body: some View {
        CatalogGate { columns }
        // 三栏从窗口上沿起，栏头排进红绿灯那一排（各栏里自己让出这一排）
        .ignoresSafeArea(.container, edges: .top)
        .previewPresenter(Bindable(workspace).preview, reply: nil)
        .background(palette.desk)
        .background { WindowPanels(workspace: workspace) }
        .background { TaskBubbleSlot() }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .overlay(alignment: .top) { NoticeView().padding(.top, Spacing.item) }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .panelHost()
        .environment(workspace)
    }

    private var columns: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let trail = sizes.cue == 0 ? CueButton.reserve : Spacing.page
            HStack(spacing: 0) {
                // 放不下时也挂着（宽 0、不放循环动效、订阅暂停）：窗口拖窄跨过临界宽的那一下主区从它上面滑过去，露出的是它本身
                WideRail(width: sizes.rail)
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading, shape: sizes.shape) {
                    MainColumn().environment(\.headInset, Self.inset(leading: Chrome.headLead(rail: sizes.rail), trailing: sizes.split ? Spacing.page : trail))
                }
                .frame(width: sizes.leading)
                if sizes.split {
                    WideColumnHost(slot: .beside, focus: focus, origin: sizes.rail + sizes.leading, width: sizes.main - sizes.leading, shape: sizes.shape) {
                        BesideColumn().environment(\.headInset, Self.inset(trailing: trail))
                    }
                    .frame(width: sizes.main - sizes.leading)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                if sizes.cueFits {
                    // 收起时排在窗口右缘外：收起、放回是同一段平移，左缘每一帧贴着主区的右缘（滑出去落定才藏起，`WideColumnSlide.park`）
                    WideColumnHost(slot: .cue, focus: focus, origin: geometry.size.width - sizes.cue, width: WideMetrics.cue, shape: sizes.shape, hidden: sizes.cue == 0) {
                        CueColumn(fits: true).environment(\.pageActive, sizes.cue > 0)
                    }
                    .frame(width: WideMetrics.cue)
                    .padding(.trailing, sizes.cue - WideMetrics.cue)
                } else {
                    // 抽屉里同样嵌在自己的托管视图里：栏头在标题栏那一排，在窗口的托管视图里时 Cue 页的滚动区伸到标题栏底下，系统在那一截盖上滚动边缘效果、栏头看不见（`ColumnHostingView`）
                    Color.clear.frame(width: 0).drawer(isPresented: $workspace.cueDrawer) { DrawerCue(focus: focus) }
                }
            }
            .overlay(alignment: .leading) {
                if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail) } }
            }
            .overlay(alignment: .topLeading) { SidebarToggle(sizes: sizes) }
            .reportsWideFits(sizes, to: workspace)
            .overlay(alignment: .topTrailing) {
                if !workspace.cueShown(sizes) { CueButton(fits: sizes.cueFits).padding(.trailing, Spacing.page).frame(height: Chrome.band) }
            }
        }
    }

    private static func inset(leading: CGFloat = Spacing.page, trailing: CGFloat) -> EdgeInsets {
        EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
    }
}

/// 抽屉里的 Cue 栏：关上滑到窗外后藏起托管视图（同收起的 Cue 栏），⌃Tab 不轮到看不见的它，也接不到键入；开的那一下当即露出。
private struct DrawerCue: View {
    let focus: WideFocus
    @Environment(\.drawerParked) private var parked

    var body: some View {
        WideColumnHost(slot: .cue, focus: focus, origin: 0, width: WideMetrics.cue, shape: WideMetrics.Shape(rail: 0, cue: WideMetrics.cue), hidden: parked) {
            CueColumn(fits: false)
        }
        .frame(width: WideMetrics.cue)
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

/// 底部输入条：盖着一页（`Workspace.overlay`；灵感的编辑页含淡出途中）时不显示，底栏只有一套，先退后进；⌘K 打开时只是藏起来（不卸下），关掉面板的同一帧就回来。
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
    /// 底部输入栏放不放（规则在 `CaptureSlot`）。
    var takesCapture: Bool {
        switch self {
        case .project, .archive: true
        default: false
        }
    }
}

extension Workspace {
    /// ⌥⌘N（"文件 › 新会话"）与看板推进中列头的 ＋（`openNewSession`）：弹出新会话的表单（表单只有这一个出处，挂在主窗口上），开在 `project`（nil 是当前项目）。
    func newSession(in project: UUID? = nil) {
        newSessionProject = project
        showsNewSession = true
    }
}

/// 窗口级快捷键：⌘1–9 切项目。⌘N 记一条灵感、⌥⌘N 新会话、⌘K 搜索、⌘⇧T 进展页、⌃⌘S 会话条开合、⌃⌘I 右栏（Cue）开合与设置（⌘,）在主菜单，Esc 关浮层在 `PanelHost`。
/// ⌘1–9 的唯一处理者在这里。
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

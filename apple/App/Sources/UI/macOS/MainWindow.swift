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
                // 预览铺满时主区被右半盖住：宽不变（不重排），滑完藏起
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.home || sizes.fill, under: under) {
                    MainColumn().environment(\.headInset, Self.inset(leading: Chrome.headLead(rail: sizes.rail), trailing: sizes.split ? Spacing.page : trail))
                        .environment(\.pageActive, !sizes.home && !sizes.fill)
                        .environment(\.underCue, under)
                }
                .frame(width: sizes.leading + under)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<WideNavigation.maxPanes - 1, id: \.self) { beside($0, sizes, window: geometry.size.width, trail: trail) }
                }
            }
            .overlay { if !sizes.fill { ForEach(0..<sizes.widths.count - 1, id: \.self) { BesideDivider(sizes: sizes, index: $0) } } }
            .overlay { if !sizes.home, !sizes.fill { railChrome(sizes) } }
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

    /// 并排时最左那块右边的第 `index` 块：没开着时也挂着、同样宽，停在窗口右缘外、滑完藏起。开合是这一块整个从右缘滑进来、滑回去（`WideColumnSlide` 的平移），
    /// 宽不变、页不重排：收起时里面的东西原样滑走，不先被压窄。活预览铺满时（`WideMetrics.fill`）它长到窗口左缘，栏让出红绿灯，别的几块滑走。
    private func beside(_ index: Int, _ sizes: WideMetrics, window: CGFloat, trail: CGFloat) -> some View {
        let origin = sizes.origin(index + 1, window: window), width = sizes.width(index + 1)
        let last = index + 2 == sizes.widths.count
        return WideColumnHost(slot: .beside(index), focus: focus, origin: origin, width: width, shape: sizes.shape, hidden: origin >= window) {
            BesideColumn(index: index) { SessionPage($0, column: .beside(index)) } card: { IdeaPane(cardID: $0, column: .beside(index)) }
                .environment(\.headInset, Self.inset(leading: sizes.fill ? Chrome.toggle : Spacing.page, trailing: last || sizes.fill ? trail : Spacing.page))
        }
        .frame(width: width)
        .padding(.leading, origin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    @State private var mountsPalette = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            // ⌘K 每天用很多次：直接出现、直接消失，不做动画
            .keptPanel(isPresented: $workspace.searching, mounted: mountsPalette) { SearchPalette() }
            .onChange(of: workspace.searching) { if $1 { mountsPalette = true } }
            .task(id: workspace.isLibraryReady) {
                guard workspace.isLibraryReady else { return }
                guard (try? await Task.sleep(for: Prewarm.delay)) != nil else { return }
                mountsPalette = true
            }
            .panel(item: $workspace.projectForm) { ProjectForm($0) }
            .modifier(NewInputPanel())
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

/// 多选灵感时浮在主区底部的那一条。
struct SelectionSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, workspace.overlay == nil, workspace.presses.presented == nil, workspace.presses.isSelecting {
            SelectionBar().padding(.bottom, Spacing.block).transition(.opacity)
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

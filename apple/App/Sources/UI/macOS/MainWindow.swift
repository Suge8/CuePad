#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页（侧栏点 Cue、任务、会话、项目，都在内容区整页切换；没有返回、前进与往上一层，
/// 导航都在侧栏，工具栏左上只在开着编辑页时有"收起"）；卡片编辑页、⌘K 搜索、底部输入栏、提示都在详情区之上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationSplitView(columnVisibility: Bindable(workspace.pages).sidebar) {
            Sidebar()
                // 系统的侧栏钮走 AppKit 的分栏动画（约 300ms 里每帧整窗重排）；换成自己的（`SidebarToggle`），与 ⌃⌘S 同一个入口。
                // 同访达：它是侧栏这一栏的工具栏项，侧栏开着时在侧栏顶上、红绿灯右边，收起后留在原处，成了工具栏最左的一颗
                .toolbar(removing: .sidebarToggle)
                .toolbar { ToolbarItem { SidebarToggle() } }
                .navigationSplitViewColumnWidth(min: 210, ideal: 256, max: 320)
        } detail: {
            SidebarMotion { detail }
                // 页的图层在滑（`MacPages.held`）：底色两边多铺一截，滑开的地方不露出窗口的底
                .background { palette.desk.padding(.horizontal, -MacPages.slideOverscan).ignoresSafeArea() }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { workspace.pages.detailMoved(toMinX: $0) }
        }
        .background { WindowPanels(workspace: workspace) }
        .background { TaskBubbleSlot() }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .panelHost()
        .environment(workspace)
    }

    private var detail: some View {
        ZStack {
            page
            EditorLayer().zIndex(1)
        }
        // 工具栏那一条垫页底色的渐变（`Bars`）：只这一处、只这一条高，页里浮着的东西（顶上那一排、提示）都在它下面
        .overlay(alignment: .top) { ToolbarFade() }
        .overlay(alignment: .bottom) { CaptureSlot() }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var page: some View {
        CatalogGate { PageStack() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // 工具栏项常驻、只换里面的内容：增删工具栏项会让 AppKit 在开合侧栏的那一帧重建整条工具栏
        ToolbarItem(placement: .navigation) { SwitcherSlot() }
        // 工具栏给条目画的玻璃底不随内容显隐（隐去时会留一个空圆钮），所以关掉它、由按钮自己画
        ToolbarItem(placement: .navigation) { CloseButton() }
            .sharedBackgroundVisibility(.hidden)
        // 这一页的范围与主操作（`ScopeSlot`、`PageActionSlot`）：常驻、固定宽度，玻璃由控件自己画
        ToolbarItem(placement: .navigation) { ScopeSlot() }
            .sharedBackgroundVisibility(.hidden)
        // 会话页与 Cue 页（侧栏收起时）的标题（`SessionHeader`、`CueTitle`，居中）；右上的"⋯"（`PageMenuSlot`）是当前页的操作。.principal 在详情区里居中，与对话的阅读栏同一条中线
        ToolbarItem(placement: .principal) { PageTitleSlot() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) { PageActionSlot() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            SyncAlert()
            // 资料库读不出来时：搜索结果能打开卡片，是写入入口
            Button("搜索", icon: .search) { workspace.searching.toggle() }
                .help("搜索（⌘K）")
                .disabled(!workspace.isLibraryReady)
        }
        ToolbarItem(placement: .primaryAction) { PageMenuSlot() }
            .sharedBackgroundVisibility(.hidden)
    }
}

/// 开合侧栏时详情区里的页（`MacPages.held`）：动之前按动画结束时的位置与宽度排好一次，动画里不再跟着变。
/// 侧栏这一栏浮在详情区上面，它的宽是详情区左边的安全区：动画的每一帧安全区都在变，页里的滚动区伸进安全区、跟着每帧变宽重排。
/// 动的时候这一块不让安全区的左边，页按终点排好一次；每帧只把详情区这一栏的图层平移到侧栏的边（`MacPages.follow`），页的左缘贴着侧栏走、不重排。
/// 否决的方案：用 SwiftUI 的偏移（`offset` 一类几何效果）逐帧挪——每帧在主线程重新摆整页、挪平台视图、重算点按与拖动区域，开合十次 27G 对 10G 指令；
/// 图层上加 Core Animation 补间——分栏的侧栏是主线程逐帧摆的，不是图层动画，两边各走各的钟，实测差出一帧（中段 30 点上下）。
/// 单独一个视图读它：主窗口的视图体不读。
private struct SidebarMotion<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    @ViewBuilder let content: Content

    var body: some View {
        let pages = workspace.pages
        HoldPlace(leading: pages.held) { content }
            .ignoresSafeArea(.container, edges: pages.held == nil ? [] : .leading)
            .background { ColumnFinder(pages: pages) }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { pages.follow(edge: $0) }
    }
}

/// 找详情区这一栏的承载视图交给 `MacPages.column`：分栏里每一栏包在一层里，再往上是分栏本身。
private struct ColumnFinder: NSViewRepresentable {
    let pages: MacPages

    func makeNSView(context: Context) -> Probe { Probe(pages: pages) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let pages: MacPages

        init(pages: MacPages) {
            self.pages = pages
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            pages.column = sequence(first: self, next: \.superview).first { $0.superview?.superview is NSSplitView }?.layer
        }
    }
}

/// 按 `leading` 排：从那里到右缘（详情区这一栏铺到窗口右边，右缘动画里不变）；nil 时铺满。
private struct HoldPlace: Layout {
    let leading: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let leading = leading ?? 0
        let origin = CGPoint(x: bounds.minX + leading, y: bounds.minY)
        for subview in subviews {
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width - leading, height: bounds.height))
        }
    }

    // 不回答对齐查询：默认实现会递归问遍整页子树
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
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

/// 底部输入条：编辑页挂着（含淡出途中）时不显示，底栏只有一套，先退后进；⌘K 打开时只是藏起来（不卸下），关掉面板的同一帧就回来。
/// 回收站、Agent 整页与会话页不放：那里不是记灵感的地方（Agent 整页有自己的"＋"新会话，会话页有回复框），它只会压住列表最后几行。
private struct CaptureSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, workspace.presses.presented == nil, workspace.presses.isSelecting {
            SelectionBar().padding(.bottom, 16).transition(.opacity)
        } else if workspace.isLibraryReady, workspace.presses.presented == nil, workspace.root.takesCapture {
            let searching = workspace.searching
            CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .animation(nil, value: searching)
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }
}

private extension Route {
    /// 底部输入栏放不放：回收站、Agent 整页与会话页不是记灵感的地方。
    var takesCapture: Bool {
        switch self {
        case .project, .archive: true
        default: false
        }
    }
}

/// 同步需要关注时（没登录 iCloud、需要你决定、出错等）在工具栏露一个图标：悬停看原因，点开设置处理。
/// 平时什么都不显示；随同步状态（数据）变化，不随布局变化。
private struct SyncAlert: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(services.syncStatus)
        if services.sync != nil, summary.tone != .calm {
            Button {
                SettingsPane.open(.general)
            } label: {
                Image(summary.icon).foregroundStyle(palette.color(summary.tone))
            }
            .help([summary.title, summary.detail, "点按在设置里处理"].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(summary.title)
        }
    }
}

extension Workspace {
    /// ⌥⌘N（"文件 › 新会话"）：去会话页、从那一页的 + 弹出新会话的表单（表单只有这一个出处）。
    func newSession() {
        show(.agent)
        showsNewSession = true
    }
}

/// 窗口级快捷键：⌘1–9 切项目。⌘N 记一条灵感、⌥⌘N 新会话、⌘K 搜索、⌘⇧T 任务页、⌃⌘S 侧栏与设置（⌘,）在主菜单，Esc 关浮层在 `PanelHost`。
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

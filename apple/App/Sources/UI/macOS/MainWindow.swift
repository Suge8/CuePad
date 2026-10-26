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
            detail
                .background { ColumnFinder(pages: workspace.pages) }
                // 开合侧栏时详情区这一栏的图层在滑（`SidebarSlide`）：底色两边多铺一截，滑开的地方不露出窗口的底
                .background { palette.desk.padding(.horizontal, -MacPages.slideOverscan).ignoresSafeArea() }
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
            LibraryItemLayer().zIndex(1)
        }
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
        // 工具栏项常驻、只换里面的内容（`ScopeSlot` 头注释）：左右各一项把控件排在一起（`LeadingSlots`、`TrailingSlots`），中间是这一页的标题。
        // 玻璃都由控件自己画：工具栏给条目画的玻璃底不随内容显隐，宽 0 时仍留着玻璃的边距与一个空圆钮
        ToolbarItem(placement: .navigation) { LeadingSlots() }
            .sharedBackgroundVisibility(.hidden)
        // 会话页的标题（`SessionHeader`）、Cue 页（侧栏收起时）的标题（`CueTitle`），居中；.principal 在详情区里居中，与对话的阅读栏同一条中线
        ToolbarItem(placement: .principal) { PageTitleSlot() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) { TrailingSlots() }
            .sharedBackgroundVisibility(.hidden)
    }
}

/// 找详情区这一栏的承载视图交给 `SidebarSlide.column`（分栏里每一栏包在一层里，再往上是分栏本身），分栏每次摆完交给 `SidebarSlide.splitResized`。
private struct ColumnFinder: NSViewRepresentable {
    let pages: MacPages

    func makeNSView(context: Context) -> Probe { Probe(pages: pages) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let pages: MacPages
        private var observer: NSObjectProtocol?

        init(pages: MacPages) {
            self.pages = pages
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            pages.slide.leaveWindow()
            guard window != nil, let column = sequence(first: self, next: \.superview).first(where: { $0.superview?.superview is NSSplitView }) else { return }
            pages.slide.column = column
            // 同步投递（queue 为 nil）：要在分栏这一次布局里处理
            observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: column.superview?.superview, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.splitResized() }
            }
        }

        private func splitResized() {
            if let split = pages.slide.column?.superview?.superview as? NSSplitView { pages.slide.splitResized(split) }
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
/// 只在项目页与归档放：回收站、进展页与会话页不是记灵感的地方（进展页的主操作是新任务、新会话，会话页有回复框），它只会压住列表最后几行。
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

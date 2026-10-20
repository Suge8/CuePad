#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页（侧栏点 Cue、会话、项目，都在内容区整页切换，侧栏的"任务"开合任务面板；没有返回、前进与往上一层，
/// 导航都在侧栏，工具栏左上只在开着编辑页时有"收起"）；卡片编辑页、⌘K 搜索、任务面板、底部输入栏、提示都在详情区之上。
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
        }
        .background { WindowPanels(workspace: workspace) }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .panelHost()
        .environment(workspace)
    }

    private var detail: some View {
        ZStack {
            palette.desk.ignoresSafeArea()
            page
            EditorLayer().zIndex(1)
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
        // 工具栏项常驻、只换里面的内容：增删工具栏项会让 AppKit 在开合侧栏的那一帧重建整条工具栏
        ToolbarItem(placement: .navigation) { SwitcherSlot() }
        // 工具栏给条目画的玻璃底不随内容显隐（隐去时会留一个空圆钮），所以关掉它、由按钮自己画
        ToolbarItem(placement: .navigation) { CloseButton() }
            .sharedBackgroundVisibility(.hidden)
        // 会话页与 Cue 页（侧栏收起时）的标题（`SessionHeader`、`CueTitle`，居中）；右上的"⋯"（`PageMenuSlot`）是当前页的操作：项常驻、只换里面的内容。.principal 在详情区里居中，与对话的阅读栏同一条中线
        ToolbarItem(placement: .principal) { PageTitleSlot() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            SyncAlert()
            // 资料库读不出来时：搜索结果能打开卡片、任务面板能增改任务，都是写入入口
            Button("搜索", icon: .search) { workspace.searching.toggle() }
                .help("搜索（⌘K）")
                .disabled(!workspace.isLibraryReady)
        }
        ToolbarItem(placement: .primaryAction) { PageMenuSlot() }
            .sharedBackgroundVisibility(.hidden)
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
            .panel(item: $workspace.openTask, style: .bubble(anchor: workspace.openTask?.anchor)) { TaskBubble(request: $0) }
            .panel(item: $workspace.projectForm) { ProjectForm(project: $0.project) }
            .panel(isPresented: $workspace.showsAgentSetup) { AgentSetupPanel() }
    }
}

/// 鼠标左键按下、松开在 AppKit 分发时就告诉工作区（本地事件监听，早于 SwiftUI 按钮识别按下）：点下的那一帧卡片就显出按下。
/// 只管本窗口的事件（监听是整个应用的）；不管 Control 加点击：它弹右键菜单，松开可能被菜单吞掉。
private struct CardPressMonitor: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> MonitorView { MonitorView(workspace: workspace) }
    func updateNSView(_ view: MonitorView, context: Context) {}

    final class MonitorView: NSView {
        private let workspace: Workspace
        private var monitor: Any?
        private static let deleteKey: UInt16 = 51

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// ⌘⌫（同访达）删鼠标停着的那张卡：在文字里时照常是删到行首，批量选择时归底部的操作栏（`SelectionBar`）。
        /// 不挂成窗口级快捷键：那样会先于编辑页、输入栏接走 ⌘⌫。
        private func deleteHovered(_ event: NSEvent) -> Bool {
            guard event.keyCode == Self.deleteKey, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  !((window?.firstResponder as? NSTextView)?.isEditable ?? false),
                  let card = workspace.presses.deletable else { return false }
            workspace.attempt { try await self.workspace.trash(card) }
            return true
        }

        /// 窗口坐标（左下为原点）换成内容的坐标（左上为原点，内容铺满整窗）。
        private func flipped(_ point: NSPoint) -> CGPoint {
            CGPoint(x: point.x, y: (window?.contentView?.bounds.height ?? 0) - point.y)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return false }
                    if event.type == .keyDown { return self.deleteHovered(event) }
                    if event.type == .leftMouseDown { self.workspace.pressed(at: self.flipped(event.locationInWindow)) }
                    if !event.modifierFlags.contains(.control) { self.workspace.presses.mouse(down: event.type == .leftMouseDown) }
                    return false
                }
                return handled ? nil : event
            }
        }
    }
}

/// 内容区：当前页与最近去过的几页都挂着（`Workspace.mountedPages`），切页只是换哪一页看得见，回访不重建、不重排、滚动位置还在。
/// 不在前台的页：不可见、点不到、屏读跳过，暂停订阅与实时状态（`pageActive`），尺寸停在离开时的值（`PageStackLayout`）。
/// 读页面的只有这里，主窗口的视图体不读它，切页时不重建整条工具栏。会话页不留，只在当前页时挂上。
private struct PageStack: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.page
        let pages = workspace.mountedPages
        let leaving = workspace.pages.leaving
        PageStackLayout(active: current) {
            ForEach(pages, id: \.self) { page in
                let active = page == current
                content(page)
                    .layoutValue(key: PageKey.self, value: page)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .environment(\.pageActive, active || page == leaving)
                    .environment(\.pagePrefetch, !active && workspace.pages.isPremounted(page))
            }
        }
    }

    @ViewBuilder private func content(_ page: Route) -> some View {
        pageView(page).modifier(WindowCardAgents(workspace: workspace))
    }

    @ViewBuilder private func pageView(_ page: Route) -> some View {
        switch page {
        case .project(let id): ProjectPage(projectID: id)
        case .archive: ArchivePage()
        case .trash: TrashPage()
        case .cue: CuePage()
        case .agent: AgentPage()
        case .session(let route): if let id = route.sessionID { SessionPage(sessionID: id).id(id) }
        default: EmptyView()  // 其余是 iOS 的页
        }
    }
}

nonisolated private struct PageKey: LayoutValueKey {
    static let defaultValue: Route? = nil
}

/// 叠放挂着的页：当前页铺满，其余的沿用它们离开时的尺寸（窗口、侧栏怎么变都不再向它们提新尺寸，也就不重排）；
/// 回到前台时按当时的尺寸排一次。不回答对齐查询（默认实现会递归问遍整页子树）。
private struct PageStackLayout: Layout {
    let active: Route

    final class Memo {
        var sizes: [Route: CGSize] = [:]
    }

    func makeCache(subviews: Subviews) -> Memo { Memo() }

    /// 默认的更新会换一份新缓存：窗口每变一次尺寸，挂着的页就忘了自己离开时的尺寸、跟着重排。
    func updateCache(_ cache: inout Memo, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) {
        for subview in subviews {
            guard let page = subview[PageKey.self] else { continue }
            if page == active { cache.sizes[page] = bounds.size }
            subview.place(at: bounds.origin, proposal: ProposedViewSize(cache.sizes[page] ?? bounds.size))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
}

/// 内容区工具栏最左：侧栏收起时的项目切换（紧跟在侧栏钮后面）。同一个工具栏项里增减（增删工具栏项会重排整条工具栏）。
/// 单独一个视图读侧栏开合：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct SwitcherSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let collapsed = workspace.pages.sidebar == .detailOnly
        // 一直挂着（收起时才有宽度）：开合侧栏的那一刻不再现建全部项目的菜单。不用 disabled：环境一变整份菜单又要重算；
        // ⌘1–9 本来就由窗口快捷键（`WorkspaceShortcuts`）接，菜单里的只是提示
        ProjectSwitcher(collapsed: collapsed)
            .frame(width: collapsed ? nil : 0, alignment: .leading)
            .clipped()
            .opacity(collapsed ? 1 : 0)
            .accessibilityHidden(!collapsed)
    }
}

/// 开合侧栏（`MacPages.toggleSidebar`，⌃⌘S 同）。收起时侧栏的 Cue 名片看不见了：不在 Cue 页、Cue 有等你或新消息时钮角上带点（`CueDot`）。
private struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 点画在标签里：工具栏把"字 + 图标"的标签换成系统按钮，挂在按钮外面的会被丢掉
        Button { workspace.pages.toggleSidebar() } label: {
            Image(.sidebar).overlay(alignment: .topTrailing) {
                if workspace.pages.sidebar == .detailOnly, workspace.page != .cue { CueDot().offset(x: 5, y: -4) }
            }
        }
        .accessibilityLabel("侧栏")
        .help("显示或隐藏侧栏（⌃⌘S）")
    }
}

/// 打开、收起卡片只改动下面三处（收起按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：
/// 主窗口的视图体不读它，开合时不重算整个窗口、不重建整条工具栏。

/// 工具栏左上的"收起"：只在开着编辑页时有（Esc 同）。工具栏项常驻、只有里面的按钮出没（增删工具栏项会重建整条工具栏）；
/// 没有编辑页时它不占位置。
private struct CloseButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if workspace.openCard != nil {
            Button { workspace.openCard = nil } label: {
                HStack(spacing: 4) {
                    Image(.back).font(.system(size: 13, weight: .semibold))
                    Text("收起").font(Typography.toolbarLabel)
                }
                .foregroundStyle(palette.ink2)
                .padding(.leading, 10).padding(.trailing, 14)
                .frame(height: Spacing.toolbarControl)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .glass(in: .capsule, interactive: true)
            .help("收起（Esc）")
        }
    }
}

/// 打开的卡的编辑页（含淡出途中）。
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
        } else if workspace.isLibraryReady, workspace.presses.presented == nil, workspace.page.takesCapture {
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
    /// ⌘1–9：打开侧栏里此刻的第 number 个项目。快捷键只绑数字，按下的那一刻才按项目目录当前的顺序取：
    /// 顺序随最近活动与置顶变化，绑在某个项目上会在顺序变了之后打开错的。没有那么多个项目时什么也不做。
    func showProject(number: Int) {
        guard let projects = catalog?.projects, projects.indices.contains(number - 1) else { return }
        show(.project(projects[number - 1].id))
    }
}

/// 窗口级快捷键：⌘1–9 切项目、⌘N 新建卡片。⌘K 搜索、⌘⇧T 任务面板、⌃⌘S 侧栏与设置（⌘,）在主菜单，Esc 关浮层在 `PanelHost`。
/// ⌘1–9 的唯一处理者在这里：工具栏的项目切换菜单收起时不响应其菜单项的快捷键（实测），菜单里的 ⌘ 只是提示。
private struct WorkspaceShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady {
                Button("记一条灵感") { newCard() }.keyboardShortcut("n")
            }
            ForEach(Array(1...9).prefix(workspace.catalog?.projects.count ?? 0), id: \.self) { number in
                Button("项目 \(number)") { workspace.showProject(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// 新卡进正在看的项目，不在项目页时进默认项目。
    private func newCard() {
        let project = workspace.currentProject ?? Project.defaultID
        workspace.attempt {
            workspace.open(try await workspace.createCard(in: project))
        }
    }
}

/// 提示里的动作（撤销、归档）：点了收起提示并做那件事；撤销另有 ⌘Z。
private struct NoticeActionButton: View {
    let action: Workspace.NoticeAction
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action.title) { workspace.run(action) }
        .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
        .buttonStyle(PressStyle())
        .padding(.horizontal, 10).frame(height: 28)
        .keyboardShortcut(action.isUndo ? KeyboardShortcut("z", modifiers: .command) : nil)
    }
}

/// 顶部居中的短提示：操作结果与错误；带动作的（撤销、完成后的归档）右边一个按钮，撤销另有 ⌘Z。
private struct NoticeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                HStack(spacing: 0) {
                    Button { if let link = notice.link { workspace.show(link); workspace.notice = nil } } label: {
                        HStack(spacing: 6) {
                            Label { Text(notice.text) } icon: { Image(notice.isError ? .failure : .done) }
                            if notice.link != nil { Image(.forward).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
                        }
                        .font(Typography.secondary.weight(.medium))
                        .foregroundStyle(notice.isError ? palette.failure : palette.ink)
                        .padding(.leading, 14).padding(.trailing, notice.action == nil ? 14 : 4).frame(height: 34)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(notice.link == nil)
                    if let action = notice.action { NoticeActionButton(action: action).padding(.trailing, 4) }
                }
                .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(Motion.quick, value: workspace.notice)
    }
}
#endif


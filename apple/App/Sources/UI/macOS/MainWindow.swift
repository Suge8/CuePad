#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页（侧栏点项目、Agent、会话，任务与灵感都在内容区整页切换；没有返回与前进的历史，
/// 工具栏左上只有"往上一层"：纸页收起、会话页回到 Agent 整页）；卡片编辑页、⌘K 搜索、任务面板、底部输入栏、提示都在详情区之上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 窗口与侧栏宽度的读数。只在这里写、只由 `PinnedPage` 读：本视图带着工具栏，读了它们就会随几何变化重算、
    /// 每次重算都重新提交整条工具栏（AppKit 随之重排窗口），形成布局反馈环。
    @State private var widths = WindowWidths()
    @State private var searchScope = SearchScope.cards

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebar) {
            Sidebar()
                // 侧栏开合时是整体滑动、宽度不变；只有拖分隔线才变
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [widths] in widths.sidebar = $0 }
                .navigationSplitViewColumnWidth(min: 210, ideal: 256, max: 320)
        } detail: {
            detail
        }
        .environment(workspace)
        .onChange(of: workspace.overlay) { if $1 == nil { searchScope = .cards } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [widths] in widths.window = $0 }
        .confirmationDialog(
            "Agent 正在工作", isPresented: busyBinding, titleVisibility: .visible
        ) {
            ForEach([DeliveryMode.steer, .followUp], id: \.self) { mode in
                Button(mode.label) { workspace.resolveBusySend(mode) }
            }
            Button("取消", role: .cancel) { workspace.busySend = nil }
        } message: {
            Text([DeliveryMode.steer, .followUp].map { "\($0.label)：\($0.explanation ?? "")" }.joined(separator: "\n"))
        }
        .sheet(item: $workspace.attaching) { TaskPicker(idea: $0).environment(workspace) }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .modifier(SessionProjectsTracker(workspace: workspace))
    }

    private var detail: some View {
        ZStack {
            palette.desk.ignoresSafeArea()
            PinnedPage(widths: widths) { page }
            EditorLayer().zIndex(1)
        }
        .overlay(alignment: .bottom) { CaptureSlot() }
        .overlay {
            // 任务面板开着时页面轻轻压暗：玻璃底下透出来的卡片不和面板里的字抢；不拦点按，页面照常可用
            if workspace.isLibraryReady, workspace.overlay == .tasks {
                Color.black.opacity(palette.dark ? 0.22 : 0.06).ignoresSafeArea().allowsHitTesting(false).transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if workspace.isLibraryReady, workspace.overlay == .tasks {
                TasksPanel()
                    .padding(.trailing, 12).padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if workspace.isLibraryReady, workspace.overlay == .search {
                // ⌘K 每天用很多次：直接出现、直接消失，不做动画
                ZStack {
                    Color.black.opacity(palette.dark ? 0.4 : 0.25).ignoresSafeArea()
                        .onTapGesture { workspace.overlay = nil }
                    SearchPalette(scope: $searchScope).padding(24)
                }
            }
        }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var page: some View {
        CatalogGate { RoutedPage() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // 工具栏项常驻、只换里面的内容：增删工具栏项会让 AppKit 在开合侧栏的那一帧重建整条工具栏
        ToolbarItem(placement: .navigation) { SwitcherSlot() }
        // 工具栏给条目画的玻璃底不随内容显隐（隐去时会留一个空圆钮），所以关掉它、由按钮自己画
        ToolbarItem(placement: .navigation) { UpButton() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            SyncAlert()
            // 资料库读不出来时：搜索结果能打开卡片、任务面板能增改任务，都是写入入口
            Button("搜索", systemImage: "magnifyingglass") { workspace.toggle(.search) }
                .help("搜索（⌘K）")
                .disabled(!workspace.isLibraryReady)
            TasksButton().disabled(!workspace.isLibraryReady)
        }
    }

    private var busyBinding: Binding<Bool> {
        Binding(get: { workspace.busySend != nil }, set: { if !$0 { workspace.busySend = nil } })
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

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window, !event.modifierFlags.contains(.control) else { return }
                    self.workspace.mouse(down: event.type == .leftMouseDown)
                }
                return event
            }
        }
    }
}

/// 内容区此刻的页。读页面的只有这里，主窗口的视图体不读它，切页时不重建整条工具栏。
private struct RoutedPage: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        switch workspace.page {
        case .project(let id): ProjectPage(projectID: id).id(id)
        case .inbox: ProjectPage(projectID: nil)
        case .archive: ArchivePage()
        case .trash: TrashPage()
        case .agent: AgentPage()
        case .session(let id): SessionPage(sessionID: id).id(id)
        }
    }
}

/// 侧栏收起时工具栏左边的项目切换。单独一个视图读侧栏开合：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct SwitcherSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.sidebar == .detailOnly { ProjectSwitcher() }
    }
}

/// 打开、收起卡片只改动下面三处（返回按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：
/// 主窗口的视图体不读它，开合时不重算整个窗口、不重建整条工具栏。

/// 工具栏左上"往上一层"（`Workspace.up`）：开着纸页时是"收起"（Esc 也行），会话页是"Agent"回到会话列表；顶层页没有它。
/// 常驻、没有可去的地方时淡掉——条目一增一减，那一帧就要重排整条工具栏。
private struct UpButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let up = workspace.up
        Button(action: workspace.goUp) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text(up == .agentList ? "Agent" : "收起").font(Typography.toolbarLabel)
            }
            .foregroundStyle(palette.ink2)
            .padding(.leading, 10).padding(.trailing, 14)
            .frame(height: Spacing.toolbarControl)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glass(in: .capsule, interactive: true)
        .opacity(up == nil ? 0 : 1)
        .allowsHitTesting(up != nil)
        .accessibilityHidden(up == nil)
        .help(up == .agentList ? "回到 Agent 会话列表" : "收起（Esc）")
        .background {
            if up == .closePaper { Button("收起", action: workspace.goUp).keyboardShortcut(.cancelAction).hidden() }
        }
        .animation(Motion.quick, value: up)
    }
}

/// 打开的卡的纸页（含缩回途中）。
private struct EditorLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, let id = workspace.presentedCard {
            CardEditorPage(cardID: id).id(id)
        }
    }
}

/// 底部输入条：纸页挂着（含缩回途中）时不显示，底栏只有一套，先退后进；⌘K 打开时只是藏起来（不卸下），关掉面板的同一帧就回来。
/// 回收站、Agent 整页与会话页不放：那里不是记灵感的地方（Agent 整页有自己的"＋"新会话，会话页有回复框），它只会压住列表最后几行。
private struct CaptureSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, workspace.presentedCard == nil, workspace.page.takesCapture {
            let searching = workspace.overlay == .search
            CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
                .animation(nil, value: searching)
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }
}

private extension Workspace.Page {
    /// 底部输入栏放不放：回收站、Agent 整页与会话页不是记灵感的地方。
    var takesCapture: Bool {
        switch self {
        case .project, .inbox, .archive: true
        case .trash, .agent, .session: false
        }
    }
}

@Observable
private final class WindowWidths {
    var window: CGFloat = 0
    var sidebar: CGFloat = 0
}

/// 页面按侧栏开合的终点宽度排版、贴左摆放：开合动画中详情区每帧变宽变窄，页面只排一次，
/// 随详情区左缘被侧栏推着走，超出的只会是窗口右缘之外（窗口自己裁掉）。不这样做时整页（卡片墙、目标栏、更早）每帧重排，是开合卡顿的主要来源。
/// 开合状态在这里读、不在主窗口读：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct PinnedPage<Page: View>: View {
    let widths: WindowWidths
    @ViewBuilder let page: Page
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let hidden = workspace.sidebar == .detailOnly
        let width: CGFloat? = widths.window > 0 ? (hidden ? widths.window : widths.window - widths.sidebar) : nil
        PinnedWidth(width: width) { page }
            // 页宽一步到终点：开合侧栏的动画事务若带进来，页面会按插值宽度逐帧重排
            .transaction(value: width) { $0.animation = nil }
    }
}

/// 把唯一的子视图按给定宽度贴左摆放；不给宽度时铺满。
/// 不往外报子视图的最小尺寸（否则分栏会为它压窄侧栏，侧栏变窄又改了页宽，形成循环），
/// 也不回答对齐查询（默认实现会递归问遍整页子树，侧栏开合时每帧一次）。
private struct PinnedWidth: Layout {
    let width: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let width = width ?? bounds.width
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: width, height: bounds.height))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
}

/// 同步需要关注时（没登录 iCloud、需要你决定、出错等）在工具栏露一个图标：悬停看原因，点开设置处理。
/// 平时什么都不显示；随同步状态（数据）变化，不随布局变化。
private struct SyncAlert: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(services.syncStatus)
        if services.sync != nil, summary.tone != .normal {
            Button {
                NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: summary.symbol).foregroundStyle(summary.color(palette))
            }
            .help([summary.title, summary.detail, "点按在设置里处理"].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityLabel(summary.title)
        }
    }
}

/// 工具栏右上角：未完成任务数。Pi 的状态只在侧栏 Pi 区与项目页 Pi 栏出现，不挂在任务计数旁（会被读成任务出了问题）。
private struct TasksButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var openCount: Int?

    var body: some View {
        Button {
            workspace.toggle(.tasks)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                if let openCount, openCount > 0 { Text("\(openCount)").monospacedDigit() }
            }
        }
        .help("任务")
        .accessibilityLabel("任务，\(openCount ?? 0) 条未完成")
        .observing(services.store, [.cards, .projects], into: $openCount) { store in
            try TaskBoard.counts(from: store).open
        }
    }
}

/// 窗口级快捷键：⌘K 搜索、⌘\ 侧栏、⌘1–9 切项目、⌘N 新建卡片、Esc 关浮层。设置（⌘,）在主菜单。
/// ⌘1–9 的唯一处理者在这里：工具栏的项目切换菜单收起时不响应其菜单项的快捷键（实测），菜单里的 ⌘ 只是提示。
private struct WorkspaceShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            Button("侧栏") { workspace.toggleSidebar() }.keyboardShortcut("\\")
            if workspace.isLibraryReady {
                Button("搜索") { workspace.toggle(.search) }.keyboardShortcut("k")
                Button("任务") { workspace.toggle(.tasks) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("记一条灵感") { newCard() }.keyboardShortcut("n")
            }
            if workspace.overlay != nil {
                Button("关闭") { workspace.overlay = nil }.keyboardShortcut(.cancelAction)
            }
            ForEach(Array((workspace.catalog?.projects ?? []).prefix(9).enumerated()), id: \.offset) { index, project in
                Button("项目 \(index + 1)") { workspace.show(.project(project.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func newCard() {
        let project = workspace.currentProject
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            workspace.overlay = nil
            workspace.openCard = card.id
        }
    }
}

/// 提示里的动作（撤销、归档）：点了收起提示并做那件事；撤销另有 ⌘Z。
struct NoticeActionButton: View {
    let action: Workspace.NoticeAction
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action.title) { workspace.run(action) }
        .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.accent)
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
                    Button { notice.link.map(follow) } label: {
                        HStack(spacing: 6) {
                            Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            if notice.link != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
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

    /// 点提示去它说的地方（随手记的落点）。
    private func follow(_ link: Workspace.Link) {
        switch link {
        case .project(let id): workspace.show(id.map(Workspace.Page.project) ?? .inbox)
        }
        workspace.notice = nil
    }
}
#endif

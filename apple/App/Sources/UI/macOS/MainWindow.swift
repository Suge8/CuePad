#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页；卡片编辑页、⌘K 搜索、任务面板、底部输入栏、提示都在详情区之上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 有效项目的 id；变化时核对保存的当前项目是否仍然存在。
    @State private var projectIDs: [UUID]?
    @State private var windowWidth: CGFloat = 0
    @State private var sidebarWidth: CGFloat = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebar) {
            Sidebar()
                // 侧栏开合时是整体滑动、宽度不变；只有拖分隔线才变
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebarWidth = $0 }
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detail
        }
        .environment(workspace)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .confirmationDialog(
            "Pi 正在工作", isPresented: busyBinding, titleVisibility: .visible
        ) {
            Button("插话（当前工具跑完后送达）") { workspace.resolveBusySend(.steer) }
            Button("排队（这一轮结束后处理）") { workspace.resolveBusySend(.followUp) }
            Button("取消", role: .cancel) { workspace.busySend = nil }
        }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .modifier(SessionProjectsTracker(workspace: workspace))
        .observing(services.store, [.projects], into: $projectIDs) { try $0.projects().map(\.id) }
        .onChange(of: projectIDs) { Task { await workspace.reconcileCurrentProject() } }
    }

    private var detail: some View {
        ZStack {
            palette.desk.ignoresSafeArea()
            PinnedWidth(width: pageWidth) { page }
                // 页宽一步到终点：开合侧栏的动画事务若带进来，页面会按插值宽度逐帧重排
                .transaction(value: pageWidth) { $0.animation = nil }
            TopFade()
            if let id = workspace.presentedCard {
                CardEditorPage(cardID: id)
                    .id(id)
                    .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) {
            // 纸页挂着（含缩回途中）时不显示：底栏只有一套，先退后进
            if workspace.presentedCard == nil, workspace.page != .trash, workspace.overlay != .search {
                CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if workspace.overlay == .tasks {
                TasksPanel()
                    .padding(.trailing, 12).padding(.top, 6)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if workspace.overlay == .search {
                // ⌘K 每天用很多次：直接出现、直接消失，不做动画
                ZStack {
                    Color.black.opacity(palette.dark ? 0.4 : 0.25).ignoresSafeArea()
                        .onTapGesture { workspace.overlay = nil }
                    SearchPalette()
                }
            }
        }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    /// 页面按侧栏开合的终点宽度排版、贴左摆放：开合动画中详情区每帧变宽变窄，页面只排一次，
    /// 随详情区左缘被侧栏推着走，超出的只会是窗口右缘之外（窗口自己裁掉）。不这样做时整页（卡片墙、目标栏、更早）每帧重排，是开合卡顿的主要来源。
    private var pageWidth: CGFloat? {
        guard windowWidth > 0 else { return nil }
        return workspace.sidebar == .detailOnly ? windowWidth : windowWidth - sidebarWidth
    }

    @ViewBuilder private var page: some View {
        switch workspace.page {
        case .project(let id): ProjectPage(projectID: id).id(id)
        case .inbox: ProjectPage(projectID: nil)
        case .trash: TrashPage()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // 工具栏项常驻、只换里面的内容：增删工具栏项会让 AppKit 在开合侧栏的那一帧重建整条工具栏
        ToolbarItem(placement: .navigation) {
            if workspace.sidebar == .detailOnly { ProjectSwitcher() }
        }
        ToolbarItem(placement: .navigation) {
            if workspace.openCard != nil {
                Button("返回", systemImage: "chevron.left") { closeCard() }
                    .keyboardShortcut(.cancelAction)
                    .help("返回项目（Esc）")
            }
        }
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
            Button("搜索", systemImage: "magnifyingglass") { workspace.toggle(.search) }
                .help("搜索（⌘K）")
            TasksButton()
        }
    }

    private func closeCard() {
        workspace.openCard = nil
    }

    private var busyBinding: Binding<Bool> {
        Binding(get: { workspace.busySend != nil }, set: { if !$0 { workspace.busySend = nil } })
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

/// 滚到工具栏下的内容先淡到桌面色，工具栏按钮后面不叠字；各页共用这一条。
/// 必须画在页面之外：macOS 把滚进工具栏区域的那段内容放在更上层，页面自己的浮层盖不住它。
private struct TopFade: View {
    @Environment(\.palette) private var palette

    // 合起来等于工具栏高度：页面停在顶部时标题不被淡掉
    private static let solid: CGFloat = 22
    private static let fade: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            palette.desk.frame(height: Self.solid)
            LinearGradient(colors: [palette.desk, palette.desk.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 工具栏右上角：未完成任务数 + 需要关注的 Pi 状态点。
private struct TasksButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var openCount: Int?

    var body: some View {
        let attention = services.pi.sessions.first { $0.state.needsAttention }
        Button {
            workspace.toggle(.tasks)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                if let openCount, openCount > 0 { Text("\(openCount)").monospacedDigit() }
                if let attention { PiDot(state: attention.state, size: 6) }
            }
        }
        .help("任务")
        .accessibilityLabel("任务，\(openCount ?? 0) 条未完成")
        .observing(services.store, [.tasks], into: $openCount) { try $0.tasks().count }
    }
}

/// 窗口级快捷键：⌘K 搜索、⌘\ 侧栏、⌘1–9 切项目、⌘N 新建卡片、Esc 关浮层。设置（⌘,）在主菜单。
/// ⌘1–9 的唯一处理者在这里：工具栏的项目切换菜单收起时不响应其菜单项的快捷键（实测），菜单里的 ⌘ 只是提示。
private struct WorkspaceShortcuts: View {
    let workspace: Workspace
    @Environment(AppServices.self) private var services
    @State private var order: [UUID]?

    var body: some View {
        ZStack {
            Button("搜索") { workspace.toggle(.search) }.keyboardShortcut("k")
            Button("侧栏") { workspace.toggleSidebar() }.keyboardShortcut("\\")
            Button("任务") { workspace.toggle(.tasks) }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("新建卡片") { newCard() }.keyboardShortcut("n")
            if workspace.overlay != nil {
                Button("关闭") { workspace.overlay = nil }.keyboardShortcut(.cancelAction)
            }
            ForEach(Array((order ?? []).prefix(9).enumerated()), id: \.offset) { index, id in
                Button("项目 \(index + 1)") { workspace.show(.project(id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .observing(services.store, [.projects, .cards], into: $order) { store in
            try SidebarOrder.projects(store.projects(), summaries: store.projectSummaries()).map(\.id)
        }
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

/// 顶部居中的短提示：操作结果与错误。
private struct NoticeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(notice.isError ? palette.failure : palette.ink)
                    .padding(.horizontal, 14).frame(height: 34)
                    .glass(in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(Motion.quick, value: workspace.notice)
    }
}
#endif

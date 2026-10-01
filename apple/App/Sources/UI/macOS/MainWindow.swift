#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页；卡片编辑页、⌘K 搜索、任务面板、底部输入栏、提示都在详情区之上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 窗口与侧栏宽度的读数。只在这里写、只由 `PinnedPage` 读：本视图带着工具栏，读了它们就会随几何变化重算、
    /// 每次重算都重新提交整条工具栏（AppKit 随之重排窗口），形成布局反馈环。
    @State private var widths = WindowWidths()

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebar) {
            Sidebar()
                // 侧栏开合时是整体滑动、宽度不变；只有拖分隔线才变
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [widths] in widths.sidebar = $0 }
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detail
        }
        .environment(workspace)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { [widths] in widths.window = $0 }
        .confirmationDialog(
            "Pi 正在工作", isPresented: busyBinding, titleVisibility: .visible
        ) {
            Button("插话（当前工具跑完后送达）") { workspace.resolveBusySend(.steer) }
            Button("排队（这一轮结束后处理）") { workspace.resolveBusySend(.followUp) }
            Button("取消", role: .cancel) { workspace.busySend = nil }
        }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .modifier(SessionProjectsTracker(workspace: workspace))
    }

    private var detail: some View {
        ZStack {
            palette.desk.ignoresSafeArea()
            PinnedPage(widths: widths, sidebarHidden: workspace.sidebar == .detailOnly) { page }
            if let id = workspace.presentedCard {
                CardEditorPage(cardID: id)
                    .id(id)
                    .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) {
            // 纸页挂着（含缩回途中）时不显示：底栏只有一套，先退后进。项目目录还没读到或读不出来时也不显示：库读不出来不给写入入口
            if workspace.catalog != nil, workspace.presentedCard == nil, workspace.page != .trash {
                // ⌘K 打开时只是藏起来（不卸下）：关掉面板的同一帧就回来
                let searching = workspace.overlay == .search
                CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
                    .opacity(searching ? 0 : 1)
                    .allowsHitTesting(!searching)
                    .accessibilityHidden(searching)
                    .animation(nil, value: searching)
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
                    SearchPalette().padding(24)
                }
            }
        }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var page: some View {
        CatalogGate { currentPage }
    }

    @ViewBuilder private var currentPage: some View {
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
            SyncAlert()
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

@Observable
private final class WindowWidths {
    var window: CGFloat = 0
    var sidebar: CGFloat = 0
}

/// 页面按侧栏开合的终点宽度排版、贴左摆放：开合动画中详情区每帧变宽变窄，页面只排一次，
/// 随详情区左缘被侧栏推着走，超出的只会是窗口右缘之外（窗口自己裁掉）。不这样做时整页（卡片墙、目标栏、更早）每帧重排，是开合卡顿的主要来源。
private struct PinnedPage<Page: View>: View {
    let widths: WindowWidths
    let sidebarHidden: Bool
    @ViewBuilder let page: Page

    var body: some View {
        let width: CGFloat? = widths.window > 0 ? (sidebarHidden ? widths.window : widths.window - widths.sidebar) : nil
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
        .observing(services.store, [.tasks], into: $openCount) { try $0.tasks().count }
    }
}

/// 窗口级快捷键：⌘K 搜索、⌘\ 侧栏、⌘1–9 切项目、⌘N 新建卡片、Esc 关浮层。设置（⌘,）在主菜单。
/// ⌘1–9 的唯一处理者在这里：工具栏的项目切换菜单收起时不响应其菜单项的快捷键（实测），菜单里的 ⌘ 只是提示。
private struct WorkspaceShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            Button("搜索") { workspace.toggle(.search) }.keyboardShortcut("k")
            Button("侧栏") { workspace.toggleSidebar() }.keyboardShortcut("\\")
            Button("任务") { workspace.toggle(.tasks) }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("新建卡片") { newCard() }.keyboardShortcut("n")
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

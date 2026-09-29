#if os(macOS)
import CueStore
import SwiftUI

/// 主窗口：玻璃侧栏 + 当前页；卡片编辑页、⌘K 搜索、任务面板、底部输入栏、提示都在详情区之上。
struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var paperSpace

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebar) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detail
        }
        .environment(workspace)
        .confirmationDialog(
            "Pi 正在工作", isPresented: busyBinding, titleVisibility: .visible
        ) {
            Button("插话（当前工具跑完后送达）") { workspace.resolveBusySend(.steer) }
            Button("排队（这一轮结束后处理）") { workspace.resolveBusySend(.followUp) }
            Button("取消", role: .cancel) { workspace.busySend = nil }
        }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .observing(services.store, [.projectDirectories], into: $workspace.directories) { try $0.projectDirectories() }
    }

    private var detail: some View {
        ZStack {
            palette.desk.ignoresSafeArea()
            page
            if let id = workspace.openCard {
                palette.desk.ignoresSafeArea().transition(.opacity)
                CardEditorPage(cardID: id, paperSpace: paperSpace)
                    .id(id)
            }
        }
        .overlay(alignment: .bottom) {
            if workspace.openCard == nil, workspace.page != .trash, workspace.overlay != .search {
                CaptureBar(project: workspace.currentProject).padding(.bottom, 16)
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
                ZStack {
                    Color.black.opacity(palette.dark ? 0.3 : 0.08).ignoresSafeArea()
                        .onTapGesture { workspace.overlay = nil }
                    SearchPalette(paperSpace: paperSpace)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { NoticeView().padding(.top, 8) }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(Motion.spatial(Motion.panel, reduceMotion: reduceMotion), value: workspace.overlay)
    }

    @ViewBuilder private var page: some View {
        switch workspace.page {
        case .project(let id): ProjectPage(projectID: id, paperSpace: paperSpace).id(id)
        case .inbox: ProjectPage(projectID: nil, paperSpace: paperSpace)
        case .trash: TrashPage()
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if workspace.sidebar == .detailOnly {
            ToolbarItem(placement: .navigation) { ProjectSwitcher() }
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
        withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) { workspace.openCard = nil }
    }

    private var busyBinding: Binding<Bool> {
        Binding(get: { workspace.busySend != nil }, set: { if !$0 { workspace.busySend = nil } })
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
            Button("侧栏") { withAnimation { workspace.toggleSidebar() } }.keyboardShortcut("\\")
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
        let store = services.store
        Task {
            do {
                let card = try await store.createCard(in: project)
                workspace.overlay = nil
                workspace.openCard = card.id
            } catch {
                workspace.fail(error)
            }
        }
    }
}

/// 顶部居中的短提示：操作结果与错误。
private struct NoticeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
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

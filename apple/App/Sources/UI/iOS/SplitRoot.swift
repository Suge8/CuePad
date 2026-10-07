#if os(iOS)
import CueStore
import SwiftUI

/// iPad（宽）：左栏项目（含任务、Agent 等入口），右侧项目页；打开的卡片纸页推在项目页上，Agent 可在右侧面板并排看。
/// 外接键盘与 Mac 对齐：⌘1–9 切项目、⌘K（及 ⌘F）搜索、⌘\ 侧栏、⌘N 新建卡片、⌘⇧N 随手记、⌘⇧T 任务、⌘, 设置。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @State private var width: CGFloat = 0

    private static let threeColumnWidth: CGFloat = 1100
    /// 侧栏与右侧面板随字号加宽（辅助字号下项目名不被截成"…"），各有上限，详情栏总留得下。
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var panelWidth: CGFloat = 360
    private static let maxSidebarWidth: CGFloat = 420
    private static let maxPanelWidth: CGFloat = 480

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: $navigation.sidebar) {
            SplitSidebar()
                .navigationSplitViewColumnWidth(
                    min: 240, ideal: min(sidebarWidth, Self.maxSidebarWidth), max: max(340, min(sidebarWidth, Self.maxSidebarWidth)))
        } detail: {
            // 右侧面板与详情栏并排（不用 .inspector：它包在分栏或导航栈上时，推入的页面拿不到导航栏的安全区，
            // 大标题与返回按钮压在内容上；挂进导航栈里又会把面板的工具栏并进详情栏）
            HStack(spacing: 0) {
                NavigationStack(path: $navigation.splitPath) {
                    page(navigation.splitRoot)
                        .navigationDestination(for: Navigation.Route.self) { page($0) }
                }
                if navigation.agentPanel {
                    Divider().ignoresSafeArea()
                    AgentPanel()
                        .frame(width: min(panelWidth, Self.maxPanelWidth))
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 窄窗口（竖屏、分屏）放不下三栏：打开右侧面板或卡片纸页时收起侧栏，纸页盖住整个右侧
        .onChange(of: navigation.agentPanel) { _, shown in
            if shown { collapseSidebarIfNarrow() }
        }
        .onChange(of: navigation.splitPath) { _, path in
            if case .card = path.last { collapseSidebarIfNarrow() }
        }
        .background { SplitShortcuts() }
        .onAppear { navigation.splitRoot = Self.route(for: workspace.page) }
    }

    /// 右侧页：Agent 面板的开关在每一页上（推入的页也有），卡片纸页除外——它有自己的复制、发送与更多。
    @ViewBuilder private func page(_ route: Navigation.Route) -> some View {
        if route.isCard {
            RouteView(route: route)
        } else {
            RouteView(route: route).toolbar { ToolbarItem(placement: .primaryAction) { AgentPanelButton() } }
        }
    }

    private func collapseSidebarIfNarrow() {
        guard width < Self.threeColumnWidth, navigation.sidebar != .detailOnly else { return }
        withAnimation(Motion.panel) { navigation.sidebar = .detailOnly }
    }

    /// 打开窗口时的右侧页：当前项目，没有项目时是项目书架（与 iPhone 首页相同）。
    static func route(for page: Workspace.Page) -> Navigation.Route {
        switch page {
        case .project(let id): .project(id)
        case .inbox: .shelf
        case .trash: .trash
        }
    }
}

/// 右侧 Agent 面板的开关；有会话等你确认时带橙点。
private struct AgentPanelButton: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var waiting: Int?

    var body: some View {
        Button { withAnimation(Motion.panel) { navigation.agentPanel.toggle() } } label: {
            Label("Agent", systemImage: "waveform.path.ecg")
                .overlay(alignment: .topTrailing) {
                    if (waiting ?? 0) > 0 { Circle().fill(palette.attention).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .accessibilityValue((waiting ?? 0) > 0 ? "\(waiting ?? 0) 个会话等你确认" : "")
        .observing(services.store, [.piSessionStates], into: $waiting) {
            try $0.piSessionPage(.live).items.filter { $0.state.state == .known(.waitingForUser) }.count
        }
    }
}

/// 右侧 Agent 面板。不套导航栈、不放工具栏：iPadOS 的详情栏只有一条工具栏，面板里的工具栏会并进去。
private struct AgentPanel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        AgentScreen(inPanel: true).countsAsPiViewer()
            .padding(.top, 8)
            .background(palette.desk.ignoresSafeArea())
    }
}

nonisolated private struct SidebarData: Sendable {
    var live: [PiSessionListItem]
    var waiting: Int
}

private struct SplitSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var data: SidebarData?

    var body: some View {
        List {
            Section {
                SidebarRow(route: .shelf, title: "项目", symbol: "books.vertical")
                SidebarRow(route: .tasks, title: "任务", symbol: "checklist")
                SidebarRow(route: .agent, title: "Agent", symbol: "waveform.path.ecg", badge: data?.waiting ?? 0)
                SidebarRow(route: .search, title: "搜索", symbol: "magnifyingglass")
            }
            if let catalog = workspace.catalog {
                let pinned = catalog.projects.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section("置顶") { ForEach(pinned) { row($0, catalog) } }
                }
                let recent = catalog.projects.filter { !$0.isPinned }
                let inbox = catalog.cardCounts[nil] ?? 0
                if !recent.isEmpty || inbox > 0 {
                    Section("最近") {
                        ForEach(recent) { row($0, catalog) }
                        if inbox > 0 { SidebarRow(route: .inbox, title: "未归档", symbol: "tray", badge: inbox) }
                    }
                }
            }
            Section {
                SidebarRow(route: .trash, title: "回收站", symbol: "trash")
                SidebarRow(route: .settings, title: "设置", symbol: "gearshape")
            }
        }
        // 侧栏用共用的侧栏层色（深色是更深一档的暖黑），不用系统偏冷的灰
        .scrollContentBackground(.hidden)
        .background(palette.sidebar)
        .navigationTitle("CuePad")
        .toolbar {
            Button("新建项目", systemImage: "folder.badge.plus") { navigation.projectForm = .init() }
        }
        .observing(services.store, [.piSessionStates, .deliveryRequests], into: $data, onError: workspace.fail) { store in
            let live = try store.piSessionPage(.live).items
            return SidebarData(live: live, waiting: live.filter { $0.state.state == .known(.waitingForUser) }.count)
        }
    }

    private func row(_ project: Project, _ catalog: ProjectCatalog) -> some View {
        let pi = PiSessionListItem.byProject(data?.live ?? [], shown: services.settings.shown)[project.id]
        return SidebarRow(route: .project(project.id), title: project.name, project: project, badge: catalog.cardCounts[project.id] ?? 0, pi: pi)
            .projectActions(project, radius: 10, pi: pi)
    }
}

/// 侧栏的一项。选中态是共用的选中底色加粗字（不是实心胶囊）：只告诉你"在这里"，不抢内容的注意。
private struct SidebarRow: View {
    let route: Navigation.Route
    let title: String
    var symbol: String?
    var project: Project?
    var badge = 0
    var pi: PiShown?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 图标随字号放大（侧栏列表里的符号默认不跟随辅助字号）。
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 16

    var body: some View {
        let selected = navigation.splitRoot == route
        Button(action: choose) {
            Label {
                // 辅助字号下名称独占一行、可换行，状态点与计数排到下一行：名称不被挤成"…"或从词中间断开
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
                layout {
                    Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    HStack(spacing: 6) {
                        if let pi { PiStateDot(shown: pi, size: 6, announces: true) }
                        Spacer(minLength: 4)
                        if badge > 0 { Text("\(badge)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3) }
                    }
                }
            } icon: {
                if let symbol { Image(systemName: symbol).font(.system(size: icon)) } else { ProjectGlyph(project: project, size: icon) }
            }
            .foregroundStyle(palette.ink)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? palette.selection : .clear)
                .padding(.horizontal, 10))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 选中项目同时记为当前项目（与 Mac 同一事实源）。
    private func choose() {
        if route == .search { navigation.openSearch(); return }
        navigation.select(route)
        switch route {
        case .project(let id): workspace.show(.project(id))
        case .inbox: workspace.show(.inbox)
        default: break
        }
    }
}

/// 外接键盘快捷键（不占位的隐形按钮）。
private struct SplitShortcuts: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    /// 新卡放进正在看的项目（搜索等页面上放进当前项目），随即打开。
    private func newCard() {
        let project = navigation.captureProject ?? workspace.currentProject
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            if navigation.splitRoot == .search { navigation.closeSearch() }
            navigation.open(card: card.id)
        }
    }

    var body: some View {
        ZStack {
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("k")
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("f")
            // 搜索框没有焦点时 Esc 退出搜索（有焦点时第一下 Esc 由系统收起输入）
            if navigation.splitRoot == .search {
                Button("退出搜索") { navigation.closeSearch() }.keyboardShortcut(.escape, modifiers: [])
            }
            Button("新建卡片", action: newCard).keyboardShortcut("n")
            Button("随手记") { navigation.startCapture() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("设置") { navigation.select(.settings) }.keyboardShortcut(",")
            Button("侧栏") {
                withAnimation(Motion.panel) { navigation.sidebar = navigation.sidebar == .detailOnly ? .automatic : .detailOnly }
            }
            .keyboardShortcut("\\")
            Button("任务") { navigation.showTasks() }.keyboardShortcut("t", modifiers: [.command, .shift])
            ForEach(Array((workspace.catalog?.projects ?? []).prefix(9).enumerated()), id: \.offset) { index, project in
                Button("项目 \(index + 1)") { navigation.show(project: project.id, workspace: workspace) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif

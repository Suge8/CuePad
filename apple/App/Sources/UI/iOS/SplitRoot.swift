#if os(iOS)
import CueStore
import SwiftUI

/// iPad（宽）：左栏项目，右侧项目页；打开的卡片纸页推在项目页上，任务与活动在右侧面板。
/// 外接键盘与 Mac 对齐：⌘1–9 切项目、⌘K（及 ⌘F）搜索、⌘\ 侧栏、⌘N 新建卡片、⌘⇧N 随手记、⌘⇧T 任务、⌘, 设置。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @State private var width: CGFloat = 0

    private static let threeColumnWidth: CGFloat = 1100

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: $navigation.sidebar) {
            SplitSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            NavigationStack(path: $navigation.splitPath) {
                RouteView(route: navigation.splitRoot)
                    .navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
                    .toolbar { ToolbarItemGroup(placement: .primaryAction) { PanelButtons() } }
            }
            .safeAreaInset(edge: .bottom) {
                if navigation.splitPath.isEmpty, showsCaptureBar { SplitCaptureBar().padding(.bottom, 12) }
            }
        }
        .inspector(isPresented: Binding(get: { navigation.panel != nil }, set: { if !$0 { navigation.panel = nil } })) {
            SidePanel().inspectorColumnWidth(min: 300, ideal: 360, max: 440)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 窄窗口（竖屏、分屏）放不下三栏：打开右侧面板或卡片纸页时收起侧栏，纸页盖住整个右侧
        .onChange(of: navigation.panel) { _, panel in
            if panel != nil { collapseSidebarIfNarrow() }
        }
        .onChange(of: navigation.splitPath) { _, path in
            if case .card = path.last { collapseSidebarIfNarrow() }
        }
        .background { SplitShortcuts() }
        .onAppear { navigation.splitRoot = Self.route(for: workspace.page) }
    }

    private func collapseSidebarIfNarrow() {
        guard width < Self.threeColumnWidth, navigation.sidebar != .detailOnly else { return }
        withAnimation(Motion.panel) { navigation.sidebar = .detailOnly }
    }

    /// 随手记栏只在内容页出现，设置、回收站这类页面不需要。
    private var showsCaptureBar: Bool {
        switch navigation.splitRoot {
        case .settings, .conflicts, .trash: false
        default: true
        }
    }

    /// 打开窗口时的右侧页：当前项目，没有项目时是今天。
    static func route(for page: Workspace.Page) -> Navigation.Route {
        switch page {
        case .project(let id): .project(id)
        case .inbox: .today
        case .trash: .trash
        }
    }
}

/// 右侧面板的开关：任务与活动；活动按钮在有会话等你确认时带橙点。
private struct PanelButtons: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @State private var waiting: Int?

    var body: some View {
        Button("任务", systemImage: "checklist") { withAnimation(Motion.panel) { navigation.toggle(.tasks) } }
        Button { withAnimation(Motion.panel) { navigation.toggle(.activity) } } label: {
            Label("活动", systemImage: "waveform.path.ecg")
                .overlay(alignment: .topTrailing) {
                    if (waiting ?? 0) > 0 { Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .accessibilityValue((waiting ?? 0) > 0 ? "\(waiting ?? 0) 个会话等你确认" : "")
        .observing(services.store, [.piSessionStates], into: $waiting) {
            try $0.piSessionStates().filter { $0.state == .waitingForUser }.count
        }
    }
}

/// 右侧面板：任务或活动，顶部分段切换。
private struct SidePanel: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        NavigationStack {
            Group {
                switch navigation.panel ?? .tasks {
                case .tasks: TasksScreen()
                case .activity: ActivityScreen()
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("面板", selection: Binding(get: { navigation.panel ?? .tasks }, set: { navigation.panel = $0 })) {
                        Text("任务").tag(Navigation.Panel.tasks)
                        Text("活动").tag(Navigation.Panel.activity)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

nonisolated private struct SidebarData: Sendable {
    var projects: [Project]
    var counts: [UUID?: Int]
    var pi: [UUID: PiWorkState]
    var waiting: Int
}

private struct SplitSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @State private var data: SidebarData?
    @State private var creating = false

    var body: some View {
        List(selection: selection) {
            Section {
                Label("今天", systemImage: "sun.max").tag(Navigation.Route.today)
                Label("活动", systemImage: "waveform.path.ecg").badge(data?.waiting ?? 0).tag(Navigation.Route.activity)
                Label("搜索", systemImage: "magnifyingglass").tag(Navigation.Route.search)
            }
            if let data {
                let pinned = data.projects.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section("置顶") { ForEach(pinned) { row($0, data) } }
                }
                Section("最近") {
                    ForEach(data.projects.filter { !$0.isPinned }) { row($0, data) }
                    if let inbox = data.counts[nil], inbox > 0 {
                        Label("未归档", systemImage: "tray").badge(inbox).tag(Navigation.Route.inbox)
                    }
                }
            }
            Section {
                Label("回收站", systemImage: "trash").tag(Navigation.Route.trash)
                Label("设置", systemImage: "gearshape").tag(Navigation.Route.settings)
            }
        }
        .navigationTitle("CuePad")
        .toolbar {
            Button("新建项目", systemImage: "folder.badge.plus") { creating = true }
        }
        .sheet(isPresented: $creating) { ProjectFormSheet(project: nil) }
        .observing(services.store, [.projects, .cards, .piSessionStates], into: $data, onError: workspace.fail) { store in
            let summaries = try store.projectSummaries()
            let states = try store.piSessionStates()
            return SidebarData(
                projects: SidebarOrder.projects(try store.projects(), summaries: summaries),
                counts: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) }),
                pi: PiSessionState.byProject(states),
                waiting: states.filter { $0.state == .waitingForUser }.count)
        }
    }

    private func row(_ project: Project, _ data: SidebarData) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(project.name)
                if let state = data.pi[project.id] { PiDot(state: state, size: 6) }
            }
        } icon: {
            ProjectGlyph(project: project, size: 15)
        }
        .badge(data.counts[project.id] ?? 0)
        .tag(Navigation.Route.project(project.id))
        .accessibilityValue(data.pi[project.id].map { "Pi \($0.label)" } ?? "")
    }

    /// 选中项目同时记为当前项目（与 Mac 同一事实源）。
    private var selection: Binding<Navigation.Route?> {
        Binding(get: { navigation.splitRoot }, set: { route in
            guard let route else { return }
            navigation.select(route)
            switch route {
            case .project(let id): workspace.show(.project(id))
            case .inbox: workspace.show(.inbox)
            default: break
            }
        })
    }
}

/// 项目页底部的玻璃随手记栏（宽 iPad 没有标签栏附件栏）。
private struct SplitCaptureBar: View {
    var body: some View {
        CaptureBar()
            .frame(maxWidth: 560).frame(height: 50)
            .glass(in: .capsule, interactive: true)
            .padding(.horizontal, 24)
    }
}

/// 外接键盘快捷键（不占位的隐形按钮）。
private struct SplitShortcuts: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @State private var order: [UUID]?

    var body: some View {
        ZStack {
            Button("搜索") { navigation.select(.search) }.keyboardShortcut("k")
            Button("搜索") { navigation.select(.search) }.keyboardShortcut("f")
            Button("设置") { navigation.select(.settings) }.keyboardShortcut(",")
            Button("侧栏") {
                withAnimation(Motion.panel) { navigation.sidebar = navigation.sidebar == .detailOnly ? .automatic : .detailOnly }
            }
            .keyboardShortcut("\\")
            Button("任务") { withAnimation(Motion.panel) { navigation.toggle(.tasks) } }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            ForEach(Array((order ?? []).prefix(9).enumerated()), id: \.offset) { index, id in
                Button("项目 \(index + 1)") { navigation.show(project: id, workspace: workspace) }
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
}
#endif

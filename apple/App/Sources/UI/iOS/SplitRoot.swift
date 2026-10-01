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

    /// 打开窗口时的右侧页：当前项目，没有项目时是项目书架（与 iPhone 首页相同）。
    static func route(for page: Workspace.Page) -> Navigation.Route {
        switch page {
        case .project(let id): .project(id)
        case .inbox: .shelf
        case .trash: .trash
        }
    }
}

/// 右侧面板的开关：任务与活动；活动按钮在有会话等你确认时带橙点。
private struct PanelButtons: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var waiting: Int?

    var body: some View {
        Button("任务", systemImage: "checklist") { withAnimation(Motion.panel) { navigation.toggle(.tasks) } }
        Button { withAnimation(Motion.panel) { navigation.toggle(.activity) } } label: {
            Label("活动", systemImage: "waveform.path.ecg")
                .overlay(alignment: .topTrailing) {
                    if (waiting ?? 0) > 0 { Circle().fill(palette.attention).frame(width: 7, height: 7).offset(x: 3, y: -2) }
                }
        }
        .accessibilityValue((waiting ?? 0) > 0 ? "\(waiting ?? 0) 个会话等你确认" : "")
        .observing(services.store, [.piSessionStates], into: $waiting) {
            try $0.piSessionStates().filter { $0.state == .known(.waitingForUser) }.count
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
    var pi: [UUID: Open<PiWorkState>]
    var waiting: Int
}

private struct SplitSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @State private var data: SidebarData?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                SidebarRow(route: .shelf, title: "项目", symbol: "books.vertical")
                SidebarRow(route: .today, title: "今天", symbol: "sun.max")
                SidebarRow(route: .activity, title: "活动", symbol: "waveform.path.ecg", badge: data?.waiting ?? 0)
                SidebarRow(route: .search, title: "搜索", symbol: "magnifyingglass")
            }
            if let data {
                let pinned = data.projects.filter(\.isPinned)
                if !pinned.isEmpty {
                    Section("置顶") { ForEach(pinned) { row($0, data) } }
                }
                let recent = data.projects.filter { !$0.isPinned }
                let inbox = data.counts[nil] ?? 0
                if !recent.isEmpty || inbox > 0 {
                    Section("最近") {
                        ForEach(recent) { row($0, data) }
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
                waiting: states.filter { $0.state == .known(.waitingForUser) }.count)
        }
    }

    private func row(_ project: Project, _ data: SidebarData) -> some View {
        SidebarRow(route: .project(project.id), title: project.name, project: project, badge: data.counts[project.id] ?? 0,
                   pi: data.pi[project.id])
    }
}

/// 侧栏的一项。选中态是共用的选中底色加粗字（不是实心胶囊）：只告诉你"在这里"，不抢内容的注意。
private struct SidebarRow: View {
    let route: Navigation.Route
    let title: String
    var symbol: String?
    var project: Project?
    var badge = 0
    var pi: Open<PiWorkState>?
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        let selected = navigation.splitRoot == route
        Button(action: choose) {
            Label {
                HStack(spacing: 6) {
                    Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    if let pi { PiDot(state: pi, size: 6) }
                    Spacer(minLength: 4)
                    if badge > 0 { Text("\(badge)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3) }
                }
            } icon: {
                if let symbol { Image(systemName: symbol) } else { ProjectGlyph(project: project, size: 15) }
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
        .accessibilityValue(pi.map { "Pi \($0.label)" } ?? "")
    }

    /// 选中项目同时记为当前项目（与 Mac 同一事实源）。
    private func choose() {
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

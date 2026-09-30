#if os(iOS)
import CueStore
import SwiftUI

/// iPad（宽）：左栏项目，右侧项目页；打开的卡片纸页推在项目页上，任务在右侧面板。
/// 外接键盘：⌘1–9 切项目、⌘F 搜索、⌘N 新建卡片、⌘⇧N 随手记、⌘⇧T 任务、⌘, 设置，与 Mac 对齐。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            SplitSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            NavigationStack(path: $navigation.splitPath) {
                RouteView(route: navigation.splitRoot)
                    .navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("任务", systemImage: "checklist") { navigation.showsTasks.toggle() }
                                .keyboardShortcut("t", modifiers: [.command, .shift])
                        }
                    }
            }
            .safeAreaInset(edge: .bottom) {
                if navigation.splitPath.isEmpty { SplitCaptureBar().padding(.bottom, 12) }
            }
        }
        .inspector(isPresented: $navigation.showsTasks) {
            NavigationStack { TasksScreen() }
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .background { SplitShortcuts() }
        .onAppear { navigation.splitRoot = Self.route(for: workspace.page) }
    }

    static func route(for page: Workspace.Page) -> Navigation.Route {
        switch page {
        case .project(let id): .project(id)
        case .inbox: .inbox
        case .trash: .trash
        }
    }
}

nonisolated private struct SidebarData: Sendable {
    var projects: [Project]
    var counts: [UUID?: Int]
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
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            let summaries = try store.projectSummaries()
            return SidebarData(
                projects: SidebarOrder.projects(try store.projects(), summaries: summaries),
                counts: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) }))
        }
    }

    private func row(_ project: Project, _ data: SidebarData) -> some View {
        Label { Text(project.name) } icon: { ProjectGlyph(project: project, size: 15) }
            .badge(data.counts[project.id] ?? 0)
            .tag(Navigation.Route.project(project.id))
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
    @Environment(Navigation.self) private var navigation

    var body: some View {
        Button { navigation.startCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").accessibilityHidden(true)
                Text("记下想法…").foregroundStyle(.secondary)
                Spacer()
                Text("⌘⇧N").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 18).frame(width: 520, height: 48)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glass(in: .capsule, interactive: true)
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .accessibilityLabel("随手记")
    }
}

/// 外接键盘快捷键：⌘1–9 切项目、⌘F 搜索、⌘, 设置。
private struct SplitShortcuts: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @State private var order: [UUID]?

    var body: some View {
        ZStack {
            Button("搜索") { navigation.select(.search) }.keyboardShortcut("f")
            Button("设置") { navigation.select(.settings) }.keyboardShortcut(",")
            ForEach(Array((order ?? []).prefix(9).enumerated()), id: \.offset) { index, id in
                Button("项目 \(index + 1)") {
                    navigation.select(.project(id))
                    workspace.show(.project(id))
                }
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

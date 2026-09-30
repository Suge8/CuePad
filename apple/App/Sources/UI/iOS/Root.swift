#if os(iOS)
import CueStore
import SwiftUI

/// 接入点：从环境取服务与本窗口状态，建出本窗口的 `Workspace`。
struct IOSRoot: View {
    @Environment(AppServices.self) private var services
    @Environment(SceneContext.self) private var scene

    var body: some View {
        IOSRootView(services: services, scene: scene)
    }
}

/// iOS/iPadOS 的根视图：窄宽用标签栏（项目 / 任务 / 活动 / 搜索），宽 iPad 用分栏。
struct IOSRootView: View {
    @State private var workspace: Workspace
    @State private var navigation = Navigation()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom
    /// 有效项目的 id；变化时核对保存的当前项目是否仍然存在。
    @State private var projectIDs: [UUID]?

    init(services: AppServices, scene: SceneContext) {
        _workspace = State(initialValue: Workspace(services: services, holder: scene))
    }

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if sizeClass == .regular { SplitRoot() } else { TabsRoot() }
        }
        .sheet(item: $navigation.capture) { CaptureSheet(capture: $0) }
        .sheet(item: $navigation.outbox) { SendToMacSheet(outbox: $0) }
        .overlay(alignment: .top) { NoticeBanner() }
        // 环境放在最外层：浮层与弹出面板是这些修饰符内容的兄弟，放在里面它们拿不到
        .environment(\.zoomNamespace, zoom)
        .modifier(InkTint())
        .modifier(PaletteProvider())
        .environment(workspace)
        .environment(navigation)
        .environment(workspace.services)
        .preferredColorScheme(scheme)
        .onChange(of: sizeClass, initial: true) { _, size in
            navigation.layout = size == .regular ? .split : .tabs
        }
        .observing(workspace.services.store, [.projects], into: $projectIDs) { try $0.projects().map(\.id) }
        .onChange(of: projectIDs) { Task { await workspace.reconcileCurrentProject() } }
        .onChange(of: workspace.services.pendingDeepLink, initial: true) {
            if let link = workspace.services.consumeDeepLink() { navigation.open(link, workspace: workspace) }
        }
        #if DEBUG
        .task { await DebugScene.prepare(workspace, navigation) }
        #endif
    }

    private var scheme: ColorScheme? {
        switch workspace.services.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// 列表与表单铺在桌面色上，与书架、项目页同一底色。
    func deskBackground() -> some View { modifier(DeskBackground()) }
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

/// 全局强调色用墨色（黑白品牌），不用系统蓝。
private struct InkTint: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.tint(palette.ink) }
}

/// 推入页面的内容（iPhone 各标签的栈与 iPad 分栏共用）。
struct RouteView: View {
    let route: Navigation.Route
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        switch route {
        case .project(let id): ProjectScreen(projectID: id)
        case .inbox: ProjectScreen(projectID: nil)
        case .today: TodayScreen()
        case .trash: TrashScreen()
        case .settings: SettingsScreen()
        case .conflicts: ConflictsScreen()
        case .activity: ActivityScreen()
        case .search: SearchScreen()
        case .card(let id):
            if let zoom {
                CardEditorScreen(cardID: id).navigationTransition(.zoom(sourceID: id, in: zoom))
            } else {
                CardEditorScreen(cardID: id)
            }
        }
    }
}

/// 标签的角标：未完成任务数、等你确认的 Pi 会话数。
nonisolated private struct Badges: Equatable, Sendable {
    var tasks: Int
    var waiting: Int
}

/// iPhone：标签栏，标签栏上方常驻随手记。
private struct TabsRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @State private var badges: Badges?

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("项目", systemImage: "books.vertical", value: Navigation.Tab.projects) {
                stack($navigation.projectsPath) { ShelfScreen() }
            }
            Tab("任务", systemImage: "checklist", value: Navigation.Tab.tasks) {
                stack($navigation.tasksPath) { TasksScreen() }
            }
            .badge(badges?.tasks ?? 0)
            Tab("活动", systemImage: "waveform.path.ecg", value: Navigation.Tab.activity) {
                stack($navigation.activityPath) { ActivityScreen() }
            }
            .badge(badges?.waiting ?? 0)
            Tab(value: Navigation.Tab.search, role: .search) {
                stack($navigation.searchPath) { SearchScreen() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(CaptureAccessoryPlacement(shown: !navigation.isEditingCard))
        .sensoryFeedback(.selection, trigger: navigation.tab)
        .observing(services.store, [.tasks, .piSessionStates], into: $badges) { store in
            Badges(tasks: try store.tasks().count, waiting: try store.piSessionStates().filter { $0.state == .waitingForUser }.count)
        }
    }

    private func stack(_ path: Binding<[Navigation.Route]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
        }
    }
}

/// 随手记栏常驻标签栏上方；打开的卡片纸页上收起（纸页本身就在输入，标签栏也藏起）。按条件收起要 iOS 26.1。
private struct CaptureAccessoryPlacement: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: shown) { CaptureAccessory() }
        } else {
            content.tabViewBottomAccessory { CaptureAccessory() }
        }
    }
}

/// 顶部的短提示：操作结果与错误。错误伴随触感。
private struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(in: .capsule)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.quick, value: workspace.notice)
        .sensoryFeedback(trigger: workspace.notice) { _, notice in
            guard let notice else { return nil }
            return notice.isError ? .error : .success
        }
        .onChange(of: workspace.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text).post() }
        }
    }
}
#endif

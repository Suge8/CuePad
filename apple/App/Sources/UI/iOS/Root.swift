#if os(iOS)
import CueStore
import SwiftUI

/// 接入点：从环境取服务与本窗口状态，建出本窗口的 `Workspace`。
struct IOSRoot: View {
    @Environment(AppServices.self) private var services
    @Environment(SceneContext.self) private var scene
    @Environment(PiAlertCenter.self) private var alerts

    var body: some View {
        IOSRootView(services: services, scene: scene, alerts: alerts)
    }
}

/// iOS/iPadOS 的根视图：窄宽用标签栏（项目 / 任务 / 活动；搜索在书架与项目页下拉），宽 iPad 用分栏。
struct IOSRootView: View {
    @State private var workspace: Workspace
    @State private var navigation = Navigation()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom
    let alerts: PiAlertCenter

    init(services: AppServices, scene: SceneContext, alerts: PiAlertCenter) {
        _workspace = State(initialValue: Workspace(services: services, holder: scene))
        self.alerts = alerts
    }

    var body: some View {
        @Bindable var navigation = navigation
        CatalogGate {
            Group {
                if sizeClass == .regular { SplitRoot() } else { TabsRoot() }
            }
            // 会写资料库的面板挂在门内：读不出资料库时（包括从小组件深链打开随手记）不弹出，读到后再弹
            .sheet(item: $navigation.capture) { CaptureSheet(capture: $0) }
            .sheet(item: $navigation.outbox) { SendToMacSheet(outbox: $0) }
            .sheet(item: $navigation.projectForm) { ProjectFormSheet(project: $0.project) }
        }
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
        .task(id: workspace.catalogAttempt) { await workspace.observeCatalog() }
        .onChange(of: workspace.services.pendingDeepLink, initial: true) {
            if let link = workspace.services.consumeDeepLink() { navigation.open(link, workspace: workspace) }
        }
        .onChange(of: alerts.pendingTap, initial: true) { navigation.open(alert: alerts.consumeTap()) }
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

/// 全局强调色用墨色（黑白品牌），不用系统蓝。
private struct InkTint: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.tint(palette.accent) }
}

/// 推入页面的内容（iPhone 各标签的栈与 iPad 分栏共用）。
struct RouteView: View {
    let route: Navigation.Route
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        switch route {
        case .shelf: ShelfScreen()
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

/// iPhone：标签栏，标签栏上方常驻随手记。
private struct TabsRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    /// 活动标签的角标：等你确认的 Pi 会话数（未完成任务不紧急，不挂角标）。
    @State private var waiting: Int?

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("项目", systemImage: "books.vertical", value: Navigation.Tab.projects) {
                stack($navigation.projectsPath) { ShelfScreen() }
            }
            Tab("任务", systemImage: "checklist", value: Navigation.Tab.tasks) {
                stack($navigation.tasksPath) { TasksScreen() }
            }
            Tab("活动", systemImage: "waveform.path.ecg", value: Navigation.Tab.activity) {
                stack($navigation.activityPath) { ActivityScreen() }
            }
            .badge(waiting ?? 0)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .observing(services.store, [.piSessionStates], into: $waiting) { store in
            try store.piSessionStates().filter { $0.state == .known(.waitingForUser) }.count
        }
    }

    private func stack(_ path: Binding<[Navigation.Route]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
        }
        // 纸页独占底部（编辑工具栏不和标签栏叠在一起）。跟纸页的出现与消失走而不是跟路径：
        // 手势返回一开始标签栏就回来，松手时页面不再跳
        .toolbarVisibility(navigation.showsCardPage ? .hidden : .visible, for: .tabBar)
    }
}

/// 顶部的短提示：操作结果与错误。错误伴随触感。
private struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(notice.isError ? AnyShapeStyle(palette.failure) : AnyShapeStyle(palette.ink))
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

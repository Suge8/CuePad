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

/// iOS/iPadOS 的根视图：窄宽用标签栏（项目 / Agent；任务从书架一行进入，搜索在书架与项目页下拉），宽 iPad 用分栏。
struct IOSRootView: View {
    @State private var workspace: Workspace
    @State private var navigation: Navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom
    let alerts: PiAlertCenter

    init(services: AppServices, scene: SceneContext, alerts: PiAlertCenter) {
        _workspace = State(initialValue: Workspace(services: services, holder: scene))
        _navigation = State(initialValue: Navigation(settings: services.settings))
        self.alerts = alerts
    }

    var body: some View {
        @Bindable var navigation = navigation
        CatalogGate {
            Group {
                if sizeClass == .regular { SplitRoot() } else { TabsRoot() }
            }
            // 会写资料库的面板挂在门内：读不出资料库时（包括从小组件深链打开随手记）不弹出，读到后再弹
            .sheet(item: $navigation.capture) {
                CaptureSheet(capture: $0)
            }
            .sheet(item: $navigation.outbox) { SessionPicker(outbox: $0) }
            .sheet(item: $navigation.projectForm) { ProjectFormSheet(project: $0.project) }
            .sheet(item: $navigation.newSession) { NewSessionSheet(start: $0) }
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

/// 推入页面的内容（iPhone 各标签的栈与 iPad 分栏共用，标签的根页也经这里）。页底色在这里一处铺在导航容器上：
/// 各页的内容要等读库（异步）才有，铺在滚动区上时数据没到的几帧整页透明、露出系统的黑。
struct RouteView: View {
    let route: Navigation.Route
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        page.containerBackground(background, for: .navigation)
    }

    /// 卡片纸页在窄屏是整页的纸，宽屏是桌面上的一张纸；其余页是桌面。
    private var background: Color {
        route.isCard && sizeClass != .regular ? palette.paper : palette.desk
    }

    @ViewBuilder private var page: some View {
        switch route {
        case .shelf: ShelfScreen()
        case .project(let id): ProjectScreen(projectID: id)
        case .inbox: InboxScreen()
        case .trash: TrashScreen()
        case .settings: SettingsScreen()
        case .conflicts: ConflictsScreen()
        case .tasks: TasksScreen()
        case .agent: AgentScreen().countsAsPiViewer()
        case .projectSessions(let id): AgentScreen(project: id).countsAsPiViewer()
        case .search: SearchScreen()
        case .session(let route): SessionScreen(id: route.id, seed: route.seed).countsAsPiViewer(session: route.id)
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
    /// Agent 标签的角标：等你确认的 Pi 会话数。
    @State private var waiting: Int?

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab("项目", systemImage: "books.vertical", value: Navigation.Tab.projects) {
                stack($navigation.projectsPath) { RouteView(route: .shelf) }
            }
            Tab("Agent", systemImage: "waveform.path.ecg", value: Navigation.Tab.agent) {
                stack($navigation.agentPath) { RouteView(route: .agent) }
            }
            .badge(waiting ?? 0)
        }
        // 随手记是底部附件：平时在标签栏上方一行，下滑时标签栏收小、它并进同一行，底部只剩一行玻璃
        // 纸页与会话页收起标签栏时附件跟着收起
        .tabViewBottomAccessory(isEnabled: navigation.bottomPages == 0) { CaptureEntry() }
        .tabBarMinimizeBehavior(.onScrollDown)
        // 窄窗口 iPad 接键盘：⌘K / ⌘F 聚焦当前页的下拉搜索（与宽屏的搜索页同一组快捷键）
        .background {
            ZStack {
                Button("搜索") { navigation.searchCurrentPage() }.keyboardShortcut("k")
                Button("搜索") { navigation.searchCurrentPage() }.keyboardShortcut("f")
                Button("随手记") { navigation.startCapture() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .observing(services.store, [.piSessionStates], into: $waiting) { store in
            try store.piSessionPage(.live).items.filter { $0.state.state == .known(.waitingForUser) }.count
        }
    }

    private func stack(_ path: Binding<[Navigation.Route]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
        }
        // 纸页与会话页独占底部。跟页面的出现与消失走而不是跟路径：手势返回一开始标签栏就回来，松手时页面不再跳
        .toolbarVisibility(navigation.bottomPages > 0 ? .hidden : .visible, for: .tabBar)
    }
}

/// 顶部的短提示：操作结果与错误。错误伴随触感。
/// 顶部的一行提示；带去处的（如随手记的落点）点它过去。
private struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                Button { if let link = notice.link { go(link) } } label: {
                    HStack(spacing: 6) {
                        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        if notice.link != nil {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                                .accessibilityHidden(true)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(notice.isError ? AnyShapeStyle(palette.failure) : AnyShapeStyle(palette.ink))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glass(in: .capsule, interactive: notice.link != nil)
                }
                .buttonStyle(.plain)
                .disabled(notice.link == nil)
                .accessibilityHint(notice.link == nil ? "" : "去那里看看")
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

    private func go(_ link: Workspace.Link) {
        workspace.notice = nil
        switch link {
        case .project(let id?): navigation.show(project: id, workspace: workspace)
        case .project(nil): navigation.showInbox()
        case .tasks: navigation.showTasks()
        }
    }
}
#endif

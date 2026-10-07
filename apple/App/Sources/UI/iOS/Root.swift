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

/// iOS/iPadOS 的根视图：窄宽是两个标签（灵感 / Agent）加底部一行（标签与"写"；任务从书架一行进入），宽 iPad 用分栏。
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
            // 随手记与新会话都是浮在键盘上方的输入框
            .overlay { FloatingInput(isPresented: navigation.capturing, close: navigation.endCapture) { CaptureComposer() } }
            .overlay {
                FloatingInput(isPresented: navigation.newSession != nil, close: { navigation.newSession = nil }) {
                    if let start = navigation.newSession { NewSessionInput(start: start).id(start.id) }
                }
            }
            .sheet(item: $navigation.outbox) { SessionPicker(outbox: $0) }
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

/// iPhone（及窄窗口 iPad）：两个标签的内容 + 底部自绘的一行（`BottomBar`）。系统标签栏隐藏，TabView 只管切内容
/// （保留各标签的导航栈与页面的出现/消失）；底部那一行不随滚动收小，进纸页、会话页时随页收起。
private struct TabsRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    /// Agent 标签的角标：等你确认的 Pi 会话数。
    @State private var waiting: Int?

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab(value: Navigation.Tab.projects) { stack($navigation.projectsPath) { RouteView(route: .shelf) } }
            Tab(value: Navigation.Tab.agent) { stack($navigation.agentPath) { RouteView(route: .agent) } }
        }
        // 内容让出底部一行的高度（滚动到它下面的内容渐隐）；那一行本身浮在上面、不随键盘升起，键盘出来时被盖住
        .safeAreaBar(edge: .bottom) {
            if navigation.bottomPages == 0 { Color.clear.frame(height: BottomBar.height + BottomBar.bottomGap) }
        }
        .overlay(alignment: .bottom) {
            if navigation.bottomPages == 0 {
                BottomBar(waiting: waiting ?? 0)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: navigation.bottomPages == 0)
        // 窄窗口 iPad 接键盘：⌘K / ⌘F 聚焦当前页的搜索（与宽屏的搜索页同一组快捷键）
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
        .toolbarVisibility(.hidden, for: .tabBar)
    }
}

/// 底部一行，整体居中：贴在一起的玻璃 [灵感 | Agent] 与一颗圆形"写"；位置与大小始终不变，不随滚动收小。
private struct BottomBar: View {
    let waiting: Int
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 62
    static let bottomGap: CGFloat = 4
    private static let inset: CGFloat = 4
    private static let tabWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 12) {
            tabs
            Button { navigation.startCapture() } label: {
                Image(systemName: WriteEntry.symbol).font(.title2.weight(.medium)).foregroundStyle(palette.ink)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .glass(in: .circle, interactive: true)
            .accessibilityLabel(WriteEntry.title)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Self.bottomGap)
    }

    /// 两格标签：底下一块玻璃，选中的那一格上一滴着色的玻璃（同一个玻璃容器里，换标签时滑过去、途中与底板相融）；
    /// 字与图标叠在玻璃之上（放进容器里会被玻璃盖住）。
    private var tabs: some View {
        GlassEffectContainer {
            ZStack(alignment: navigation.tab == .projects ? .leading : .trailing) {
                Capsule().fill(.clear)
                    .frame(width: Self.tabWidth * 2 + Self.inset * 2, height: Self.height)
                    .glassEffect(.regular, in: .capsule)
                Capsule().fill(.clear)
                    .frame(width: Self.tabWidth, height: Self.height - Self.inset * 2)
                    .glassEffect(.regular.tint(palette.selection), in: .capsule)
                    .padding(Self.inset)
            }
        }
        .overlay {
            HStack(spacing: 0) {
                tab(.projects, title: "灵感", symbol: "lightbulb")
                tab(.agent, title: "Agent", symbol: "waveform.path.ecg", badge: waiting)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
        }
    }

    private func tab(_ tab: Navigation.Tab, title: String, symbol: String, badge: Int = 0) -> some View {
        let selected = navigation.tab == tab
        return Button {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { navigation.tab = tab }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3.weight(selected ? .semibold : .regular))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) { if badge > 0 { Badge(count: badge).offset(x: 12, y: -6) } }
                Text(title).font(.caption2.weight(selected ? .semibold : .medium))
            }
            .foregroundStyle(palette.ink)
            .frame(width: Self.tabWidth, height: Self.height - Self.inset * 2)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(badge > 0 ? "\(badge) 个会话等你确认" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 角标：注意色的小胶囊（等你确认数），跟随字号。
private struct Badge: View {
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        Text("\(count)").font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(palette.attention, in: .capsule)
            .accessibilityHidden(true)
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

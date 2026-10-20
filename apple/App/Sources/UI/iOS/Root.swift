#if os(iOS)
import SwiftUI

/// iOS/iPadOS 一个窗口的根视图（建出本窗口的 `Workspace` 与 `Navigation`）：宽屏是分栏（`SplitRoot`），窄屏（iPhone 与窄窗口 iPad）
/// 是以当前去处为根的导航栈加底部一排（`DockRoot`）。两种容器读写同一份 `Navigation`。
struct IOSRoot: View {
    @State private var workspace: Workspace
    @State private var navigation: Navigation
    /// 页面此刻不躲键盘（浮起的输入框开着，或刚收起、键盘还没落下）。
    @State private var pageIgnoresKeyboard = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Namespace private var zoom
    let alerts: AlertCenter

    init(services: AppServices, alerts: AlertCenter) {
        _workspace = State(initialValue: Workspace(services: services))
        _navigation = State(initialValue: Navigation(settings: services.settings))
        self.alerts = alerts
    }

    var body: some View {
        @Bindable var navigation = navigation
        CatalogGate {
            Group {
                if sizeClass == .regular { SplitRoot() } else { DockRoot() }
            }
            .background { RootShortcuts() }
            // 浮起的输入框（新会话、发给 Agent）盖在页面上、自己随键盘升起：这时页面不躲键盘，
            // 否则键盘一出来、一收起，底下整页都要按新的安全区重排一遍
            .ignoresSafeArea(pageIgnoresKeyboard ? .keyboard : [], edges: .bottom)
            .onChange(of: navigation.floating) { _, floating in if floating { pageIgnoresKeyboard = true } }
            // 收起时等键盘落下再恢复躲键盘（收起的一刻键盘还在，马上恢复就是多排一遍）；页里自己的输入框要弹键盘时立刻恢复
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                if !navigation.floating { pageIgnoresKeyboard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if !navigation.floating { pageIgnoresKeyboard = false }
            }
            // 会写资料库的面板挂在门内：读不出资料库时不弹出，读到后再弹；新会话与发给 Agent 都是浮在键盘上方的输入框
            .overlay {
                FloatingInput(isPresented: navigation.newSession != nil, close: { navigation.newSession = nil }) {
                    if let start = navigation.newSession { NewSessionInput(start: start).id(start.id) }
                }
            }
            .overlay {
                FloatingInput(isPresented: navigation.outbox != nil, close: { navigation.outbox = nil }) {
                    if let outbox = navigation.outbox { HandOffInput(outbox: outbox).id(outbox.id) }
                }
            }
            .sheet(item: $navigation.projectForm) { ProjectFormSheet(project: $0.project, created: $0.created) }
            .sheet(item: Binding(get: { workspace.folderPicker }, set: { workspace.folderPicker = $0 })) { FolderPickerSheet(project: $0) }
        }
        // 这一层还没有导航栏：上安全区就是状态栏
        .measuresStatusBar()
        // 窄屏盖在整个窗口上；宽屏在右边那一栏里（`SplitRoot`）
        .overlay(alignment: .top) { if sizeClass != .regular { NoticeBanner() } }
        // 卡与行上"交给了哪个会话"的状态点读窗口里的那一份（`Workspace.agentLinks`）
        .modifier(WindowCardAgents(workspace: workspace))
        // Cue 与会话之间接力的那一下画在整个窗口上
        .modifier(CueRelayStage(workspace: workspace))
        // 环境放在最外层：浮层与弹出面板是这些修饰符内容的兄弟，放在里面它们拿不到
        .environment(\.zoomNamespace, zoom)
        .modifier(PaletteProvider())
        .environment(workspace)
        .environment(navigation)
        .environment(workspace.services)
        .preferredColorScheme(scheme)
        .onChange(of: sizeClass, initial: true) { navigation.compact = sizeClass != .regular }
        .task { await workspace.follow() }
        .modifier(SessionViewing(keeper: workspace.services.sessionViewer, navigation: navigation))
        .onChange(of: workspace.services.pendingDeepLink, initial: true) {
            if let link = workspace.services.consumeDeepLink() { navigation.open(link) }
        }
        .onChange(of: alerts.pendingTap, initial: true) { navigation.open(alert: alerts.consumeTap()) }
        .debugScene(workspace, navigation)
    }

    private var scheme: ColorScheme? {
        switch workspace.services.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 右边那一栏的页（侧栏选中的根页与其上推入的页都经这里）。页底色在这里一处铺在导航容器上：
/// 各页的内容要等读库（异步）才有，铺在滚动区上时数据没到的几帧整页透明、露出系统的黑。
struct RouteView: View {
    let route: Route
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.statusBarBottom) private var statusBar
    @Environment(\.homePage) private var homePage
    /// 这一页的上沿（全局坐标）：状态栏那一条的渐变按它摆到屏幕顶上（`StatusBarFade`）。页的上沿不一定在屏幕顶，
    /// 也不能靠 `ignoresSafeArea` 伸上去：根页让出的顶栏那一排也在安全区里，伸上去落在那一排下面。
    @State private var top: CGFloat = 0

    var body: some View {
        // 沉浸式：内容一直滚到顶栏、回复框的玻璃后面、透到屏幕最顶，玻璃本身就是遮挡，玻璃之间与下面的内容清楚可见——
        // 系统的滚动边缘效果（渐进模糊带，盖住整条栏）全关；只有状态栏那一条垫一层页底色的渐变（`Bars`）。
        // 内容离顶栏的距离只在这里给（`Bars.contentGap`，让出在上安全区里），静止时第一行在顶栏下面。顶上那一排自己画的页（搜索页、Cue 页头、
        // 窄屏的根）自己让到那一排下面（系统分组列表默认在顶上再留一段空，这里清掉，离栏多远只有这一个数）
        page.contentMargins(.top, route.ownsTopBar ? nil : 0, for: .scrollContent)
            .safeAreaPadding(.top, route.ownsTopBar || homePage ? 0 : Bars.contentGap)
            .overlay(alignment: .top) { StatusBarFade(color: background).frame(height: statusBar).offset(y: -top) }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top = $0 }
            .containerBackground(background, for: .navigation)
            // 标题在顶栏玻璃里（推入页）或不写（窄屏的根，`homePage`），不用系统大标题
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectHidden()
            // 导航栈里的页自己跟着键盘让位（UIKit 给的安全区，不经外层），菜单开着时在这里锁住
            .modifier(KeyboardHold())
    }

    /// 卡片纸页在窄屏是整页的纸，宽屏是桌面上的一张纸；其余页是桌面。
    private var background: Color {
        route.isCard && sizeClass != .regular ? palette.paper : palette.desk
    }

    @ViewBuilder private var page: some View {
        switch route {
        case .shelf: ShelfScreen()
        case .project(let id): ProjectScreen(projectID: id)
        case .unfiled: UnfiledScreen()
        case .archive: ArchiveList().floatingHeader("归档")
        case .trash: TrashScreen()
        case .settings: SettingsScreen()
        case .conflicts: ConflictsScreen()
        case .tasks: TasksScreen()
        case .cue: CuePage().countsAsPiViewer()
        case .cueSettings: CueSettingsScreen()
        case .agent: AgentScreen().countsAsPiViewer()
        case .projectSessions(let id): AgentScreen(project: id).countsAsPiViewer()
        case .search: SearchScreen()
        case .session(let route): SessionScreen(id: route.id, seed: route.seed).countsAsPiViewer()
        case .card(let id):
            if let zoom {
                CardEditorScreen(cardID: id).navigationTransition(.zoom(sourceID: id, in: zoom))
            } else {
                CardEditorScreen(cardID: id)
            }
        }
    }
}

/// 状态栏那一条（屏幕顶到状态栏下沿）的页底色渐变：时间那一段实、到状态栏下沿淡完，时间与电池不压在字上；
/// 渐变随页走（推入、换去处时跟着页挪），颜色就是这一页的底色。不接点按、读屏跳过。
private struct StatusBarFade: View {
    let color: Color
    /// 几档：时间、信号与电池那一段（上半截多一点）实，字压不到它们下面；往下缓缓淡完，没有一条看得见的边，灵动岛以下的内容透出来。
    private static let stops: [(alpha: Double, at: CGFloat)] = [(1, 0), (1, 0.55), (0.75, 0.7), (0.35, 0.85), (0, 1)]

    var body: some View {
        LinearGradient(stops: Self.stops.map { .init(color: color.opacity($0.alpha), location: $0.at) }, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 外接键盘快捷键（不占位的隐形按钮），两种容器同一组，与 Mac 对齐：⌘1–9 切项目、⌘K（及 ⌘F）搜索、⌘\ 侧栏（宽屏）、⌘N 新建卡片、
/// ⌘⇧N 对 Cue 说、⌘⇧T 任务、⌘, 设置。
struct RootShortcuts: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    /// 新卡放进正在看的项目（不在项目里时进未分类），随即打开。
    private func newCard() {
        let project = navigation.currentProject
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            navigation.push(.card(card.id))
        }
    }

    var body: some View {
        ZStack {
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("k")
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("f")
            // 搜索框没有焦点时 Esc 退出搜索（有焦点时第一下 Esc 由系统收起输入）
            if navigation.top == .search {
                Button("退出搜索") { navigation.closeSearch() }.keyboardShortcut(.escape, modifiers: [])
            }
            Button("记一条灵感", action: newCard).keyboardShortcut("n")
            Button("对 Cue 说") { navigation.speakToCue() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("设置") { navigation.select(.settings) }.keyboardShortcut(",")
            Button("侧栏") {
                withAnimation(Motion.panel) { navigation.sidebar = navigation.sidebar == .detailOnly ? .automatic : .detailOnly }
            }
            .keyboardShortcut("\\")
            Button("任务") { navigation.show(.tasks) }.keyboardShortcut("t", modifiers: [.command, .shift])
            ForEach(Array((workspace.catalog?.projects ?? []).prefix(9).enumerated()), id: \.offset) { index, project in
                Button("项目 \(index + 1)") { navigation.show(.project(project.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif

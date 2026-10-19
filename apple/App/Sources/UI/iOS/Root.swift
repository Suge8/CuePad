#if os(iOS)
import SwiftUI

/// iOS/iPadOS 一个窗口的根视图（建出本窗口的 `Workspace` 与 `Navigation`）：各种宽度都是同一个分栏（`SplitRoot`），iPhone 上由系统折叠成一层层的页。
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
            SplitRoot()
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
        // 窄屏（折成一层层的页）盖在整个窗口上；宽屏在右边那一栏里（`SplitRoot`）
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
        // 变宽后两栏都在：此后再变窄，折叠出来的是右边那一页（不停在列表上）
        .onChange(of: sizeClass) { _, size in if size == .regular { navigation.column = .detail } }
        .task { await workspace.follow() }
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

    var body: some View {
        // 沉浸式：内容一直滚到顶栏、回复框的玻璃后面，玻璃本身就是唯一的遮挡，玻璃之间与下面的内容清楚可见——
        // 系统的滚动边缘效果（渐进模糊带，盖住整条栏）全关，也不自绘遮罩、渐变或色带，状态栏下也不（`Bars`）。
        // 内容离顶栏的距离只在这里给（`Bars.contentGap`，让出在上安全区里），静止时第一行在顶栏下面。顶上自带那一排的页（搜索页、Cue 页头）
        // 自己让到那一排下面（系统分组列表默认在顶上再留一段空，这里清掉，离栏多远只有这一个数）
        page.contentMargins(.top, route.ownsTopBar ? nil : 0, for: .scrollContent)
            .safeAreaPadding(.top, route.ownsTopBar ? 0 : Bars.contentGap)
            .containerBackground(background, for: .navigation)
            // 右边的页都不用大标题（推入页的标题在顶栏玻璃里，Cue、搜索自带顶上一排）：不随打开的第一页是谁而变
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
#endif

#if os(iOS)
import CueStore
import SwiftUI

/// iOS/iPadOS 一个窗口的根视图（建出本窗口的 `Workspace` 与 `Navigation`）：窄宽是两个标签（灵感 / Agent）加底部一行（标签与"写"；任务从书架一行进入），宽 iPad 用分栏。
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
                if sizeClass == .regular { SplitRoot() } else { TabsRoot() }
            }
            // 浮起的输入框（随手记、新会话、发给 Agent）盖在页面上、自己随键盘升起：这时页面不躲键盘，
            // 否则键盘一出来、一收起，底下整页（连同另一个标签里的页）都要按新的安全区重排一遍
            .ignoresSafeArea(pageIgnoresKeyboard ? .keyboard : [], edges: .bottom)
            .onChange(of: navigation.floating) { _, floating in if floating { pageIgnoresKeyboard = true } }
            // 收起时等键盘落下再恢复躲键盘（收起的一刻键盘还在，马上恢复就是多排一遍）；页里自己的输入框要弹键盘时立刻恢复
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                if !navigation.floating { pageIgnoresKeyboard = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if !navigation.floating { pageIgnoresKeyboard = false }
            }
            // 会写资料库的面板挂在门内：读不出资料库时（包括从小组件深链打开随手记）不弹出，读到后再弹
            // 随手记与新会话都是浮在键盘上方的输入框
            .overlay { FloatingInput(isPresented: navigation.capturing, close: navigation.endCapture) {
                CaptureComposer(state: $navigation.capture, defaultProject: navigation.currentProject, pinnedOpen: true, saved: navigation.finishCapture)
            } }
            .overlay {
                FloatingInput(isPresented: navigation.newSession != nil, close: { navigation.newSession = nil }) {
                    if let start = navigation.newSession { NewSessionInput(start: start).id(start.id) }
                }
            }
            // 发给 Agent 的输入框；任务浮窗开着时由浮窗自己浮起（浮在浮窗下面会被挡住）
            .overlay {
                FloatingInput(isPresented: navigation.task == nil && navigation.outbox != nil, close: { navigation.outbox = nil }) {
                    if let outbox = navigation.outbox { HandOffInput(outbox: outbox).id(outbox.id) }
                }
            }
            .sheet(item: $navigation.task) { TaskSheet(id: $0.id) }
            .sheet(item: $navigation.projectForm) { ProjectFormSheet(project: $0.project) }
            .sheet(item: Binding(get: { workspace.folderPicker }, set: { workspace.folderPicker = $0 })) { FolderPickerSheet(project: $0) }
            .panel(item: Binding(get: { workspace.attaching }, set: { workspace.attaching = $0 })) { TaskPicker(idea: $0) }
        }
        // 这一层还没有导航栏：上安全区就是状态栏，各页只在这一条里淡出（`fadesUnderBars`）
        .measuresStatusBar()
        // Cue 页在屏上时提示排在它的页头下面（`CuePage`），不浮在顶上
        .overlay(alignment: .top) { if workspace.services.cueViewers == 0 { NoticeBanner() } }
        // 卡与行上"交给了哪个会话"的状态点读窗口里的那一份（`Workspace.agentLinks`）
        .modifier(WindowCardAgents(workspace: workspace))
        // 环境放在最外层：浮层与弹出面板是这些修饰符内容的兄弟，放在里面它们拿不到
        .environment(\.zoomNamespace, zoom)
        .modifier(PaletteProvider())
        .environment(workspace)
        .environment(navigation)
        .environment(workspace.services)
        .preferredColorScheme(scheme)
        .onChange(of: sizeClass, initial: true) { _, size in
            navigation.layout = size == .regular ? .split : .tabs
        }
        .task(id: workspace.catalogAttempt) { await workspace.observeCatalog() }
        .task { await workspace.observeAgentLinks() }
        .task { await workspace.observeFolderGuide() }
        .task { await workspace.observeCue() }
        .onChange(of: workspace.services.pendingDeepLink, initial: true) {
            if let link = workspace.services.consumeDeepLink() { navigation.open(link) }
        }
        .onChange(of: alerts.pendingTap, initial: true) { navigation.open(alert: alerts.consumeTap()) }
        // 前台时会话"等你确认"、"做完了"的提示：正看着那个会话或 Agent 列表时不弹；后台走系统推送
        .onChange(of: workspace.services.sessionAlert) { _, alert in
            guard let alert, navigation.showsAlert(about: alert.session) else { return }
            workspace.say(alert.text, symbol: alert.symbol, link: .session(alert.session), duration: .seconds(5))
        }
        // 弹出后才进了那个会话（或 Agent 列表）：当场撤下
        .onChange(of: workspace.notice.map(navigation.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
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

/// 推入页面的内容（iPhone 各标签的栈与 iPad 分栏共用，标签的根页也经这里）。页底色在这里一处铺在导航容器上：
/// 各页的内容要等读库（异步）才有，铺在滚动区上时数据没到的几帧整页透明、露出系统的黑。
struct RouteView: View {
    let route: Route
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.bottomBarReserve) private var bottomBarReserve

    var body: some View {
        // 沉浸式：内容一直滚到顶栏、底部栏、回复框的玻璃后面，玻璃本身就是唯一的遮挡，玻璃之间与下面的内容清楚可见——
        // 系统的滚动边缘效果（渐进模糊带，盖住整条栏）全关，也不自绘渐变或色带；只有滚进状态栏时间那一段的内容淡出（`fadesUnderBars`）。
        // 内容离顶栏的距离只在这里给（`Bars.contentGap`，让出在上安全区里），静止时第一行在顶栏下面。顶上自带那一排的页（`SearchRow`）
        // 自己让到那一排下面（系统分组列表默认在顶上再留一段空，这里清掉，离栏多远只有这一个数）
        page.contentMargins(.top, route.hasSearchRow ? nil : 0, for: .scrollContent)
            .safeAreaPadding(.top, route.hasSearchRow ? 0 : Bars.contentGap)
            .fadesUnderBars()
            .containerBackground(background, for: .navigation)
            .scrollEdgeEffectHidden()
            // 标签栏布局：内容让出底部那一行的高度，滚到底时最后一行不被底部栏盖住。挂在每一页上：TabView 外面的安全区传不进标签页。
            // 底部栏在不在只看这一页是不是独占底部的页，不读全局的"独占底部的页有几个"：那个数在推入、返回会话页与纸页时变，
            // 读它的话两个标签里每一页（包括被盖住的）都要跟着重排一遍
            .safeAreaPadding(.bottom, route.ownsBottom ? 0 : bottomBarReserve)
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

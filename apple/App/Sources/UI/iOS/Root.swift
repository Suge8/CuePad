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
            #if DEBUG
            .overlay { if DebugScene.scene == "style" { StyleBoard() } }
            #endif
            .overlay {
                FloatingInput(isPresented: navigation.newSession != nil, close: { navigation.newSession = nil }) {
                    if let start = navigation.newSession { NewSessionInput(start: start).id(start.id) }
                }
            }
            // 交给 Agent 的输入框；任务浮窗开着时由浮窗自己浮起（浮在浮窗下面会被挡住）
            .overlay {
                FloatingInput(isPresented: navigation.task == nil && navigation.outbox != nil, close: { navigation.outbox = nil }) {
                    if let outbox = navigation.outbox { HandOffInput(outbox: outbox).id(outbox.id) }
                }
            }
            .sheet(item: $navigation.task) { TaskSheet(id: $0.id) }
            .sheet(item: $navigation.projectForm) { ProjectFormSheet(project: $0.project) }
            .sheet(item: Binding(get: { workspace.folderPicker }, set: { workspace.folderPicker = $0 })) { FolderPickerSheet(project: $0) }
        }
        .overlay(alignment: .top) { NoticeBanner() }
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
        .onChange(of: workspace.services.pendingDeepLink, initial: true) {
            if let link = workspace.services.consumeDeepLink() { navigation.open(link, workspace: workspace) }
        }
        .onChange(of: alerts.pendingTap, initial: true) { navigation.open(alert: alerts.consumeTap()) }
        // 前台时会话"等你确认"、"做完了"的提示：正看着那个会话或 Agent 列表时不弹；后台走系统推送
        .onChange(of: workspace.services.sessionAlert) { _, alert in
            guard let alert, navigation.showsAlert(about: alert.session) else { return }
            workspace.say(alert.text, symbol: alert.symbol, link: .session(alert.session), duration: .seconds(5))
        }
        #if DEBUG
        .task { await DebugScene.prepare(workspace, navigation, alerts) }
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

/// 推入页面的内容（iPhone 各标签的栈与 iPad 分栏共用，标签的根页也经这里）。页底色在这里一处铺在导航容器上：
/// 各页的内容要等读库（异步）才有，铺在滚动区上时数据没到的几帧整页透明、露出系统的黑。
struct RouteView: View {
    let route: Navigation.Route
    @Environment(Navigation.self) private var navigation
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.bottomBarReserve) private var bottomBarReserve

    var body: some View {
        // 底部栏是玻璃：滚到它后面的内容淡到页面底色（挂在让出高度之内，安全区才含底部栏那一段）
        page.overlay(alignment: .bottom) {
            if bottomBarReserve > 0, navigation.bottomPages == 0 { EdgeFade(edge: .bottom, fade: BottomBar.fadeAbove) }
        }
            .containerBackground(background, for: .navigation)
            .environment(\.pageBackground, background)
            // 标签栏布局：内容让出底部那一行的高度，滚动到它下面的内容渐隐。挂在每一页上：TabView 外面的安全区传不进标签页
            .safeAreaBar(edge: .bottom) {
                if bottomBarReserve > 0, navigation.bottomPages == 0 { Color.clear.frame(height: bottomBarReserve) }
            }
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
        case .archive: ArchiveList().floatingHeader("归档")
        case .trash: TrashScreen()
        case .settings: SettingsScreen()
        case .conflicts: ConflictsScreen()
        case .tasks: TasksScreen()
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

/// iPhone（及窄窗口 iPad）：两个标签的内容 + 底部自绘的一行（`BottomBar`）。系统标签栏隐藏，TabView 只管切内容
/// （保留各标签的导航栈、滚动位置与页面的出现/消失）；点底部换标签时页面按标签顺序推移（`TabSlide`）。
/// 底部那一行不随滚动收小，进纸页、会话页时随页收起。
private struct TabsRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Agent 标签的角标：等你确认的 Pi 会话数。
    @State private var waiting: Int?
    @State private var slide = TabSlide()
    /// 安全区底边离屏幕底边的距离（键盘弹出时是键盘高）：底部栏按屏幕底边摆，内容在安全区之上再让到栏顶。
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab(value: Navigation.Tab.projects) { stack(.projects, $navigation.projectsPath) { RouteView(route: .shelf) } }
            Tab(value: Navigation.Tab.agent) { stack(.agent, $navigation.agentPath) { RouteView(route: .agent) } }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
        .environment(\.bottomBarReserve, BottomBar.reserve(above: safeBottom))
        // 底部那一行浮在上面、离屏幕底边固定距离（不随键盘升起，键盘出来时被盖住）；内容给它让出的高度在每一页上（`RouteView`）
        .overlay(alignment: .bottom) {
            if navigation.bottomPages == 0 {
                BottomBar(waiting: waiting ?? 0, select: select)
                    .ignoresSafeArea(edges: .bottom)
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
            try store.piSessionPage(.live).items.filter(\.state.waitsForYou).count
        }
    }

    /// 点底部换标签：选中滴滑过去，页面同向推移。
    private func select(_ tab: Navigation.Tab) {
        guard tab != navigation.tab else { return }
        slide.leave(to: tab, reduceMotion: reduceMotion)
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { navigation.tab = tab }
    }

    private func stack(_ tab: Navigation.Tab, _ path: Binding<[Navigation.Route]>, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: path) {
            root().navigationDestination(for: Navigation.Route.self) { RouteView(route: $0) }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .environment(\.tabPageReady) { [slide] in slide.ready(tab) }
        .background { TabSlide.Probe(slide: slide, tab: tab) }
    }
}

/// 换标签的推移：拍下要离开的那一页盖在上面，照常切标签（页面不重建，出现/消失、导航栈与滚动位置都由 TabView 管），
/// 等新的一页有了内容（标签根页读到数据时报 `tabPageReady`）再一起推：新页从选中滴去的那一侧推入，旧页的快照往另一边推出。
/// 第一次切到某一页时它要现建、现读，旧页就多停那几十毫秒，不露出空白；减弱动态效果时新页直接在位，旧页的快照淡出。
/// 动的只是两张视图层，不碰页面的状态。
@MainActor
private final class TabSlide {
    private static let duration = 0.28
    /// 新页迟迟没报有内容（读库出错）时最多等这么久，不让快照一直盖着。
    private static let readyTimeout = 0.3

    private var pending: (tab: Navigation.Tab, reduceMotion: Bool, snapshot: UIView)?
    private var pages: [Navigation.Tab: UIView] = [:]
    private var filled: Set<Navigation.Tab> = []
    private var animator: UIViewPropertyAnimator?
    private weak var tabs: UITabBarController?

    /// 切标签之前：完成上一次推移，拍下此刻的页面盖在上面；新页已有内容就立刻推，否则等它。
    func leave(to tab: Navigation.Tab, reduceMotion: Bool) {
        animator?.stopAnimation(false)
        animator?.finishAnimation(at: .end)
        guard let container = tabs?.view, let snapshot = container.snapshotView(afterScreenUpdates: false) else { return }
        container.addSubview(snapshot)
        pending = (tab, reduceMotion, snapshot)
        start()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in self?.start(force: true) }
    }

    /// 一个标签根页有了内容。
    func ready(_ tab: Navigation.Tab) {
        filled.insert(tab)
        start()
    }

    private func start(force: Bool = false) {
        guard let (tab, reduceMotion, snapshot) = pending, let page = pages[tab], force || filled.contains(tab) else { return }
        pending = nil
        let width = page.bounds.width * (tab == .agent ? 1 : -1)
        if !reduceMotion { page.transform = CGAffineTransform(translationX: width, y: 0) }
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.2 : Self.duration, dampingRatio: 1) {
            if reduceMotion {
                snapshot.alpha = 0
            } else {
                page.transform = .identity
                snapshot.transform = CGAffineTransform(translationX: -width, y: 0)
            }
        }
        animator.addCompletion { _ in
            page.transform = .identity
            snapshot.removeFromSuperview()
        }
        animator.startAnimation()
        self.animator = animator
    }

    /// 挂在每个标签页里：认出标签控制器（快照拍它的视图）与这一页在标签控制器里的那一层（推它）。
    struct Probe: UIViewControllerRepresentable {
        let slide: TabSlide
        let tab: Navigation.Tab

        func makeUIViewController(context: Context) -> Controller { Controller(slide: slide, page: tab) }
        func updateUIViewController(_ controller: Controller, context: Context) {}

        final class Controller: UIViewController {
            let slide: TabSlide
            let page: Navigation.Tab

            init(slide: TabSlide, page: Navigation.Tab) {
                self.slide = slide
                self.page = page
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) { nil }

            override func viewIsAppearing(_ animated: Bool) {
                super.viewIsAppearing(animated)
                guard let tabs = tabBarController else { return }
                var root: UIViewController = self
                while let parent = root.parent, parent !== tabs { root = parent }
                slide.tabs = tabs
                slide.pages[page] = root.view
                slide.start()
            }
        }
    }
}

extension EnvironmentValues {
    /// 内容给 iPhone 底部栏让出的高度（`BottomBar.reserve`）；分栏布局为 0。
    @Entry var bottomBarReserve: CGFloat = 0
    /// 标签根页读到数据时调用（换标签的推移等它，见 `TabSlide`）；不在标签栏布局里时什么都不做。
    @Entry var tabPageReady: () -> Void = {}
}

/// 底部一行：左边一块玻璃里的两个标签 [灵感 | Agent]，右边一颗同高同玻璃的圆形"写"，与系统悬浮标签栏（照片、音乐：标签组靠左、
/// 搜索圆钮靠右）同一几何——高 62、离屏幕左右与底边都是 21（与屏幕圆角同心），选中滴同心内缩 4；不随滚动收小。
/// 玻璃上不另铺底；选中那一格是一层中性的滴（浅色压暗、深色更暗，同系统）加靛青的图标与字，未选中的是墨色。
/// 字号固定、不随动态字体放大，辅助字号下长按任一格或"写"弹出大内容查看器——系统标签栏同款取舍：栏高固定，字放大只会挤掉图标。
/// 按住选中的那一格时滴轻轻一压，按住另一格时手指下亮出一层淡按压底，都给一下轻触感；换标签时滴在轨道里滑过去
/// （减弱动态效果时淡出淡入、不压）。
private struct BottomBar: View {
    let waiting: Int
    let select: (Navigation.Tab) -> Void
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正按着的那一格。
    @State private var pressed: Navigation.Tab?

    private static let height: CGFloat = 62
    private static let margin: CGFloat = 21
    /// 选中滴离轨道的边。
    private static let inset: CGFloat = 4
    private static let tabWidth: CGFloat = 90
    private static let icon: CGFloat = 20

    /// 内容在安全区之上还要给底部栏让出的高度（栏顶到安全区底边）；键盘盖住底部栏时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin - safeBottom) }
    /// 底部栏上沿往上再淡出这么高（`EdgeFade`）。
    static let fadeAbove: CGFloat = 20

    private var drop: Color { palette.dark ? Color.black.opacity(0.3) : palette.ink.opacity(0.07) }

    var body: some View {
        HStack(spacing: 12) {
            tabs
            Spacer(minLength: 0)
            Button { navigation.startCapture() } label: {
                Image(systemName: WriteEntry.symbol).font(.system(size: Self.icon, weight: .medium)).foregroundStyle(palette.ink)
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .glass(in: .circle, interactive: true)
            .accessibilityLabel(WriteEntry.title)
            .accessibilityShowsLargeContentViewer { Label(WriteEntry.title, systemImage: WriteEntry.symbol) }
        }
        .padding(.horizontal, Self.margin)
        .padding(.bottom, Self.margin)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: pressed) { _, now in now != nil }
    }

    /// 一块玻璃是轨道，选中滴是轨道里的一层底（玻璃不叠玻璃）；字与图标在最上面。
    private var tabs: some View {
        // 减弱动态效果时换成每格各一滴：换标签是旧滴淡出、新滴淡入（随 `Motion.spatial` 的短淡入淡出），不滑过去
        Capsule().fill(drop)
            .frame(width: Self.tabWidth, height: Self.height - Self.inset * 2)
            .scaleEffect(pressed == navigation.tab && !reduceMotion ? 0.94 : 1)
            .animation(Motion.press, value: pressed)
            .padding(Self.inset)
            .id(reduceMotion ? navigation.tab : nil)
            .transition(.opacity)
            .frame(width: Self.tabWidth * 2 + Self.inset * 2, alignment: navigation.tab == .projects ? .leading : .trailing)
            .glass(in: .capsule, interactive: true)
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
        return Button { select(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: Self.icon, weight: selected ? .semibold : .medium))
                    .frame(height: Self.icon + 4)
                    .overlay(alignment: .topTrailing) { if badge > 0 { Badge(count: badge).dynamicTypeSize(...DynamicTypeSize.xLarge).offset(x: 13, y: -5) } }
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? palette.signature : palette.ink)
            // 一格占轨道的一半，四周的边也算它的：点在滴外面一点也算点中
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 按住没选中的这一格：手指下亮出一层比选中滴淡一半的底，与滴同大同心
                if pressed == tab, !selected {
                    Capsule().fill(drop.opacity(0.5)).padding(Self.inset).transition(.opacity)
                }
            }
            .animation(Motion.press, value: pressed)
            .contentShape(.rect)
        }
        .buttonStyle(TabPress(tab: tab, pressed: $pressed))
        .accessibilityElement(children: .ignore)
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
        .accessibilityLabel(title)
        .accessibilityValue(badge > 0 ? "\(badge) 个会话等你确认" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 标签的按下：字不缩（缩的是选中滴，见 `BottomBar`），只把"正按着哪一格"报上去。
private struct TabPress: ButtonStyle {
    let tab: Navigation.Tab
    @Binding var pressed: Navigation.Tab?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, down in
            if down { pressed = tab } else if pressed == tab { pressed = nil }
        }
    }
}

/// 角标：注意色的小胶囊（等你确认数）。比标签字（10）小一档、9 起步，跟随字号放大；上限 xLarge 加在调用处——
/// `@ScaledMetric` 读的是角标外面的字号，加在 body 里限不住它；再大就盖住图标。
private struct Badge: View {
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 16

    var body: some View {
        Text("\(count)").font(.system(size: size, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 4).frame(minWidth: diameter, minHeight: diameter)
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
                HStack(spacing: 0) {
                    Button { if let link = notice.link { go(link) } } label: {
                        HStack(spacing: 6) {
                            Label(notice.text, systemImage: notice.symbol ?? (notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                            if notice.link != nil {
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(notice.isError ? AnyShapeStyle(palette.failure) : AnyShapeStyle(palette.ink))
                        .padding(.leading, 16).padding(.trailing, notice.action == nil ? 16 : 8).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(notice.link == nil)
                    // 提示里的动作：撤销刚才那一下，或完成任务后的归档
                    if let action = notice.action {
                        Button(action.title) { workspace.run(action) }
                        .fontWeight(.semibold).foregroundStyle(palette.accent)
                        .padding(.trailing, 16).padding(.leading, 8).frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                }
                .font(.subheadline.weight(.medium))
                .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
                // 浮在内容之上：一点投影把它和底下的纸分开
                .shadow(color: .black.opacity(palette.dark ? 0.3 : 0.12), radius: 12, y: 4)
                .accessibilityHint(notice.link == nil ? "" : "去那里看看")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(notice.id)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // 让到顶上那一排（推入页的悬浮顶栏、标签根页自己画的搜索与按钮行）下面：返回钮、标题与按钮不被遮住
        .padding(.top, FloatingHeaderLayout.height + 12)
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
        case .session(let id): navigation.show(session: id)
        }
    }
}
#endif

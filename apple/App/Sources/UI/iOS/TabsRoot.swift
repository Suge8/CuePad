#if os(iOS)
import CueStore
import SwiftUI

/// iPhone（及窄窗口 iPad）：两个标签的内容 + 底部自绘的一行（`BottomBar`）。系统标签栏隐藏，TabView 只管切内容
/// （保留各标签的导航栈、滚动位置与页面的出现/消失）；点底部换标签时页面按标签顺序推移（`TabSlide`）。
/// 底部那一行不随滚动收小，进纸页、会话页时随页收起。
struct TabsRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                BottomBar(waiting: services.liveSessions.waiting, select: select)
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: navigation.bottomPages == 0)
        .onAppear { DebugHooks.selectTab = select }
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
#endif

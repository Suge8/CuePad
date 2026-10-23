#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：一个导航栈，根是底部那一排的四个去处横排成的一条（项目、任务、会话、Cue，`HomePager`：左右滑跟手切页），
/// 推入的页照常由系统返回（返回钮、内容区右滑），返回后在 Cue 页左滑前进回刚才那页。其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 导航栈托管在 UIKit 里，几个栈交替时 SwiftUI 不逐帧挪它（旧页停着、最后一下才跳走）：所以只有一个栈，切页挪的是栈根里的四页（各在自己的托管控制器里，`PagerController`）。
/// 底部那一排整个窗口只有一份（`DockBar`），挂在栈的根上、不在哪一页里：切页时它不重建、不跟着滑，与页同一刻原地换形（`morph`）。
/// 每页各建一排时，新页那一排要从旧的样子摆出第一帧再长回来，"⋯"展开着换去处就是收成圆再长开的一下来回。
/// Cue 页的输入框在页里（随键盘升起），底边那一格同一时刻只有一个主人（`handed`）：换形一开始离开输入框的样子就交给 Cue 钮，
/// 长成输入框的那条弹簧做完（动画的完成回调）才交还给页里的输入框。不按延时交接：玻璃不跟延时的不透明度动画，当场就藏了。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 底部那一排此刻画成的样子：跟着该有的样子（`DockLook.init`）换形，出现前为 nil。
    @State private var look: DockLook?
    /// 底边那一格交给了 Cue 页里的输入框；Cue 钮等输入框画上屏才藏起（`released`）。
    @State private var handed = false
    @State private var released = false
    /// Cue 页的输入框有焦点：底部那一排让开，输入框占满整排。只活在窄屏的容器里，宽屏没有它，变宽再变窄也不留旧值。
    @State private var composing = false
    /// Cue 页底部的"⋯"展开成了三格：点别处、滚动或点 Cue 钮收起，回到 Cue 页总是收起的。同样只活在窄屏的容器里。
    @State private var placesOpen = false
    @State private var width: CGFloat = 0
    /// 推入的页离开前拍的快照（左滑前进时跟手用）。
    @State private var shot = LeaveShot()

    var body: some View {
        @Bindable var workspace = workspace
        let root = workspace.root
        let target = DockLook(route: root, placesOpen: placesOpen, composing: composing)
        NavigationStack(path: $workspace.path) {
            HomePager(composing: composing, shot: shot) {
                ZStack(alignment: .bottom) {
                    // "⋯"展开时铺在 Cue 页上的一层：点一下或一划就收起
                    if placesOpen, root == .cue {
                        Color.clear.contentShape(.rect)
                            .onTapGesture { placesOpen = false }
                            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in placesOpen = false })
                            .accessibilityHidden(true)
                    }
                    DockBar(route: root, look: look ?? target, released: released, placesOpen: $placesOpen, width: max(0, width - Dock.margin * 2))
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .environment(\.dockComposer, handed)
            .environment(\.dockComposing, $composing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .toolbarVisibility(.hidden, for: .navigationBar)
            // 只有推在 Cue 页上的页能前进回来：只有它们离开前拍快照
            .navigationDestination(for: Route.self) { route in
                if root == .cue { RouteView(route: route).leaveShot(route, into: shot) } else { RouteView(route: route) }
            }
        }
        .onChange(of: target, initial: true) { morph(to: target) }
        .debugExposesPlaces { placesOpen = true }
        // 有焦点时"⋯"收起
        .onChange(of: composing) { if composing { placesOpen = false } }
        .onChange(of: root) {
            // 输入框离开页就没了焦点；回到 Cue 页是收起的样子，离开时不收：收起再长回三格就是换去处时那一下来回
            composing = false
            if root == .cue { placesOpen = false }
        }
    }

    /// 换成 `target` 的样子：换去处时与页的推移同一刻起、同一条弹簧。离开输入框的样子当场收回底边那一格，长成输入框做完才交出去。
    private func morph(to target: DockLook) {
        let composer = target != .places
        guard look != nil, !reduceMotion else {
            look = target
            handed = composer
            released = composer
            return
        }
        if !composer {
            handed = false
            released = false
        }
        withAnimation(Motion.dock) {
            look = target
        } completion: {
            guard look == target, composer else { return }
            handed = true
            // 输入框的玻璃从藏着到画出来要几帧，这期间 Cue 钮还在，底边不空
            Task {
                await NextFrame.drawn()
                if handed { released = true }
            }
        }
    }
}

/// 栈的根上的一个去处：它的页。项目、任务、会话三页顶上那一排左边一颗搜索钮、右边这一页的那一个操作，不写标题
/// （底部的选中格已经说了在哪一页，`HeaderHost.page`），内容一直滚到底部那一排后面；Cue 页顶上只有 Cue 的名牌，输入框在它自己的页里（随键盘升起）。
struct HomePage: View {
    let route: Route
    /// 安全区底边离屏幕底边多远（键盘弹出时是键盘高）。
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        RouteView(route: route)
            .environment(\.headerHost, .page(search: route != .cue))
            .environment(\.pageNamedElsewhere, true)
            // 内容一直滚到 Dock 后面，最后一行停在 Dock 上面
            .safeAreaPadding(.bottom, route == .cue ? 0 : Dock.reserve(above: safeBottom))
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
    }
}

enum Dock {
    static let height: CGFloat = 62
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页"⋯"与输入框之间的空。
    static let gap: CGFloat = 8
    static let inset: CGFloat = 4
    /// Cue 页上收起时那颗"⋯"（与输入框同高）。
    static let slot = ComposerMetrics.slot
    /// 一格最宽：宽的窄窗口（iPad）里格子不再长，多出来的给 Cue 钮。
    static let maxCell: CGFloat = 76
    /// 三个去处，从左到右：项目、任务、会话（会话挨着 Cue：接力的光从 Cue 落到它那一格最近）。
    static let places: [SidebarOutline.Entry] = [.allProjects, .tasks, .sessions]
    /// 根上的四页从左到右（三格去处，Cue 在最右）：左右滑切页与点按换去处时整条滑的顺序（`HomePager`）。
    static let pages: [Route] = places.map(\.route) + [.cue]

    /// 一格多宽：整排按五格分（三格去处、两格 Cue），中间不空。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / 5) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    static func order(_ route: Route) -> Int { pages.firstIndex(of: route) ?? pages.count - 1 }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}

/// 底部那一排该是什么样子：三页上与 Cue 页点开"⋯"时是三格，Cue 页上是"⋯"加输入框，输入框有焦点时都让开。
enum DockLook {
    case places, cue, composing

    init(route: Route, placesOpen: Bool, composing: Bool) {
        guard route == .cue, !placesOpen else {
            self = .places
            return
        }
        self = composing ? .composing : .cue
    }
}

extension SidebarOutline.Entry {
    /// 底部那一排里的叫法：书架在窄屏就是"项目"那一页。
    var dockTitle: String { self == .allProjects ? "项目" : title }
    var dockIcon: Icon { self == .allProjects ? .projects : icon }
}

extension EnvironmentValues {
    /// 底边那一格交给了 Cue 页里的输入框（`DockRoot.handed`）：没交过来时输入框藏着，那里是长成它的 Cue 钮。
    @Entry var dockComposer = true
    /// Cue 页输入框的焦点交给底部那一排（`DockRoot.composing`）；宽屏没有底部那一排，为 nil。
    @Entry var dockComposing: Binding<Bool>?
}
#endif

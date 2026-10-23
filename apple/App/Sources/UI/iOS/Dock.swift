#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：一个导航栈，根是底部那一排的四个去处横排成的一条（项目、任务、会话、Cue，`HomePager`：左右滑跟手切页），
/// 推入的页照常由系统返回（返回钮、内容区右滑），返回后在 Cue 页左滑前进回刚才那页。其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 导航栈托管在 UIKit 里，几个栈交替时 SwiftUI 不逐帧挪它（旧页停着、最后一下才跳走）：所以只有一个栈，切页挪的是栈根里的四页（各在自己的托管控制器里，`PagerController`）。
/// 底部那一排整个窗口只有一份（`DockBar`），挂在栈的根上、不在哪一页里：切页时它不重建、不跟着滑，选中的滴与换形跟着条（`PagerMotion`）走，拖到哪长到哪。
/// 每页各建一排时，新页那一排要从旧的样子摆出第一帧再长回来，"⋯"展开着换去处就是收成圆再长开的一下来回。
/// Cue 页的输入框在页里（随键盘升起），底边那一格在换形里与 Cue 钮交叉，浓淡都是条的位置与"⋯"开合的函数（`DockHandoff`）。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 根上那一条此刻在哪（`PagerController` 写）。
    @State private var motion = PagerMotion()
    /// Cue 页的输入框有焦点：底部那一排让开，输入框占满整排。只活在窄屏的容器里，宽屏没有它，变宽再变窄也不留旧值。
    @State private var composing = false
    @State private var width: CGFloat = 0
    /// 推入的页离开前拍的快照（左滑前进时跟手用）。
    @State private var shot = LeaveShot()

    var body: some View {
        @Bindable var workspace = workspace
        let root = workspace.root
        NavigationStack(path: $workspace.path) {
            HomePager(motion: motion, composing: composing, shot: shot) {
                ZStack(alignment: .bottom) {
                    PlacesCatcher(motion: motion, onCue: root == .cue) { openPlaces(false) }
                    DockBar(route: root, motion: motion, composing: composing, width: max(0, width - Dock.margin * 2), openPlaces: openPlaces)
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .environment(\.dockMotion, motion)
            .environment(\.dockComposing, $composing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .toolbarVisibility(.hidden, for: .navigationBar)
            // 只有推在 Cue 页上的页能前进回来：只有它们离开前拍快照
            .navigationDestination(for: Route.self) { route in
                if root == .cue { RouteView(route: route).leaveShot(route, into: shot) } else { RouteView(route: route) }
            }
        }
        .debugExposesPlaces { openPlaces(true) }
        // 有焦点时"⋯"收起
        .onChange(of: composing) { if composing { openPlaces(false) } }
        // 输入框离开页就没了焦点
        .onChange(of: root) { composing = false }
    }

    /// "⋯"展开、收起（点别处、滚动、点 Cue 钮、输入框有焦点时收起）：底部那一排用 `Motion.dock` 换形。
    private func openPlaces(_ open: Bool) {
        guard open != motion.placesOpen else { return }
        withAnimation(Motion.spatial(Motion.dock, reduceMotion: reduceMotion)) { motion.placesOpen = open }
    }
}

/// "⋯"展开时铺在 Cue 页上的一层：点一下或一划就收起。开合只重算这一小块：读在 `DockRoot` 里，每开合一次根上四页的内容都要整份重设（`HomePager`）。
private struct PlacesCatcher: View {
    let motion: PagerMotion
    let onCue: Bool
    let close: () -> Void

    var body: some View {
        if motion.placesOpen, onCue {
            Color.clear.contentShape(.rect)
                .onTapGesture(perform: close)
                .gesture(DragGesture(minimumDistance: 4).onChanged { _ in close() })
                .accessibilityHidden(true)
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
    /// 去处，从左到右：项目、进展（进展挨着 Cue：接力的光从 Cue 落到它那一格最近）。
    static let places: [SidebarOutline.Entry] = [.projects, .progress]
    /// 根上的几页从左到右（去处，Cue 在最右）：左右滑切页与点按换去处时整条滑的顺序（`HomePager`）。
    static let pages: [Route] = places.map(\.route) + [.cue]

    /// 一格多宽：整排按去处的格数加两格 Cue 分，中间不空。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / CGFloat(places.count + 2)) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    static func order(_ route: Route) -> Int { pages.firstIndex(of: route) ?? pages.count - 1 }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}

extension EnvironmentValues {
    /// Cue 页输入框的焦点交给底部那一排（`DockRoot.composing`）；宽屏没有底部那一排，为 nil。
    @Entry var dockComposing: Binding<Bool>?
}
#endif

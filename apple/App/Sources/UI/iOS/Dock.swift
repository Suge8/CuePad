#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：一个导航栈，根是底部那一排的三个去处横排成的一条（项目、进展、Cue，`HomePager`：左右滑跟手切页），
/// 推入的页照常由系统返回（返回钮、内容区右滑），返回后在 Cue 页左滑前进回刚才那页。其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 导航栈托管在 UIKit 里，几个栈交替时 SwiftUI 不逐帧挪它（旧页停着、最后一下才跳走）：所以只有一个栈，切页挪的是栈根里的三页（各在自己的托管控制器里，`PagerController`）。
/// 底部那一排整个窗口只有一份（`DockBar`），盖在导航栈上、不在哪一页里：切页时它不重建、不跟着滑，选中与换形跟着条（`PagerMotion`）走；
/// 推入的页上也留着（同系统标签栏，`Dock.stays`），推入、返回时它不动。
/// 每页各建一排时，新页那一排要从旧的样子摆出第一帧再长回来，"⋯"展开着换去处就是收成圆再长开的一下来回。
/// Cue 页的输入框在页里（随键盘升起），底边那一格在换形里与 Cue 钮交叉，浓淡都是条的位置与"⋯"开合的函数（`DockHandoff`）。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 根上那一条此刻在哪（`PagerController` 写）。
    @State private var motion = PagerMotion()
    /// 推入的页离开前拍的快照（左滑前进时跟手用）。
    @State private var shot = LeaveShot()

    var body: some View {
        @Bindable var workspace = workspace
        let root = workspace.root
        NavigationStack(path: $workspace.path) {
            HomePager(motion: motion, shot: shot)
                .environment(\.dockMotion, motion)
                .toolbarVisibility(.hidden, for: .navigationBar)
                // 只有推在 Cue 页上的页能前进回来：只有它们离开前拍快照
                .navigationDestination(for: Route.self) { route in
                    if root == .cue {
                        RouteView(route: route).dockReserve(Dock.stays(on: route)).leaveShot(route, into: shot)
                    } else {
                        RouteView(route: route).dockReserve(Dock.stays(on: route))
                    }
                }
        }
        .overlay {
            // 底部那一排按窗口的宽在同一遍排版里排，不写回状态：打开时先按 0 宽排一遍，玻璃就多变一次形
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    PlacesCatcher(motion: motion, onCue: workspace.top == .cue) { openPlaces(false) }
                    DockBar(
                        motion: motion, width: max(0, proxy.size.width - Dock.margin * 2),
                        stays: stays, forwardStays: workspace.forward.map(Dock.stays) ?? true, openPlaces: openPlaces)
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .debugExposesPlaces { openPlaces(true) }
        // 有焦点时"⋯"收起
        .onChange(of: motion.composing) { if motion.composing { openPlaces(false) } }
        // 推入的页盖住根：底部那一排展开成两格加 Cue 钮（Cue 页的输入框留在 Cue 页里），返回 Cue 页再收回
        .onChange(of: workspace.path.isEmpty, initial: true) { _, root in
            withAnimation(Motion.spatial(Motion.dock, reduceMotion: reduceMotion)) {
                motion.covered = !root
                motion.placesOpen = false
            }
        }
    }

    /// 浮起的输入框（新会话、发给 Agent）开着时底边归它，这一排让开：它落在这一排的位置上，留着就是两层玻璃叠着。
    private var stays: Bool { workspace.newSession == nil && workspace.outbox == nil && Dock.stays(on: workspace.top) }

    /// "⋯"展开、收起（点别处、滚动、点 Cue 钮、输入框有焦点时收起）：底部那一排用 `Motion.dock` 换形。
    private func openPlaces(_ open: Bool) {
        guard open != motion.placesOpen else { return }
        withAnimation(Motion.spatial(Motion.dock, reduceMotion: reduceMotion)) { motion.placesOpen = open }
    }
}

/// "⋯"展开时铺在 Cue 页上的一层：点一下或一划就收起。开合只重算这一小块：读在 `DockRoot` 里，每开合一次根上三页的内容都要整份重设（`HomePager`）。
private struct PlacesCatcher: View {
    let motion: PagerMotion
    let onCue: Bool
    let close: () -> Void

    var body: some View {
        if motion.placesOpen, onCue {
            Color.clear.contentShape(.rect)
                .onTapGesture(perform: close)
                .gesture(DragGesture(minimumDistance: 4).onChanged { _ in close() })
                .transition(.identity)
                .accessibilityHidden(true)
        }
    }
}

/// 栈的根上的一个去处：它的页。顶上那一排是搜索入口（`search`）与右边这一页的那一个操作，不写标题
/// （底部的选中格已经说了在哪一页，`HeaderHost.page`），内容一直滚到底部那一排后面；Cue 页顶上只有 Cue 的名牌，输入框在它自己的页里（随键盘升起）。
struct HomePage: View {
    let route: Route

    var body: some View {
        RouteView(route: route)
            .environment(\.headerHost, .page(search: Dock.search(on: route)))
            // Cue 页的底边是它自己的输入框
            .dockReserve(route != .cue)
    }
}

extension View {
    /// 内容一直滚到底部那一排后面，最后一行停在它上面（`shown` 为假的页底边归自己）。
    func dockReserve(_ shown: Bool) -> some View { modifier(DockReserve(shown: shown)) }
}

private struct DockReserve: ViewModifier {
    let shown: Bool

    /// 让多少看安全区底边离屏幕底边多远（键盘弹出时是键盘高），在同一遍排版里读：写回状态的话，打开页面、键盘起落时都先按旧的排一遍再挪。
    func body(content: Content) -> some View {
        if shown {
            GeometryReader { proxy in content.safeAreaPadding(.bottom, Dock.reserve(above: proxy.safeAreaInsets.bottom)) }
        } else {
            content
        }
    }
}

enum Dock {
    static let height: CGFloat = 62
    /// 离屏幕左、右、下边的空：同系统悬浮标签栏自带的边距（`DockTabs` 靠它对齐）。
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页"⋯"与输入框之间的空。
    static let gap: CGFloat = 8
    /// 两格离底板两端的空（同系统标签栏的排法，`DockTabs`）。
    static let inset: CGFloat = 4
    /// Cue 页上收起时那颗"⋯"（与输入框同高）。
    static let slot = ComposerMetrics.slot
    /// 一格最宽：宽的窄窗口（iPad）里格子不再长，多出来的给 Cue 钮。
    static let maxCell: CGFloat = 76
    /// 两个去处，从左到右：项目、进展（进展挨着 Cue：会话在进展里，接力的光从 Cue 落到它那一格最近）。
    static let places: [SidebarOutline.Entry] = [.projects, .progress]
    /// 根上的三页从左到右（两格去处，Cue 在最右）：左右滑切页与点按换去处时整条滑的顺序（`HomePager`）。
    static let pages: [Route] = places.map(\.route) + [.cue]

    /// 一格多宽：整排按格数分（每格去处一份、Cue 钮两份），中间不空；两格的胶囊与 Cue 钮差不多一样宽，不像缺了一格。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / CGFloat(places.count + 2)) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    static func order(_ route: Route) -> Int { pages.firstIndex(of: route) ?? pages.count - 1 }

    /// 根上这一页页顶那一排的搜索入口：项目页中间没有别的，是铺满的一条搜索框；进展页中间放着这一页看什么，是左边一颗圆钮；
    /// Cue 页的焦点就是 Cue，没有。提示横幅按它决定盖多宽（`NoticeBanner`）。
    static func search(on route: Route) -> HeaderSearch? {
        switch route {
        case .shelf: .field
        case .progress: .button
        default: nil
        }
    }

    /// 这一页上留不留着底部那一排（同系统标签栏：往下钻的页都留着，回到哪一格、换去处随时点得到）。
    /// 会话页与卡片纸页让开：底边是它们自己的（回复框、整页的纸与键盘），在那里专心说、专心写，同"信息"的对话与"备忘录"的一条。
    static func stays(on route: Route) -> Bool {
        switch route {
        case .session, .card: false
        default: true
        }
    }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}
#endif

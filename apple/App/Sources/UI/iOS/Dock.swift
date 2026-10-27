#if os(iOS)
import SwiftUI
import UIKit

/// 窄屏（iPhone 与窄窗口 iPad）的容器：项目、进展、Cue 三个 tab（`Dock.tabs`），每个 tab 一个导航栈（`Workspace.stacks`），叠在一起、只露选中的那个；
/// 底部那一排整个窗口一份（`DockBar`），盖在几个栈上：点哪一格换到哪个 tab（`Workspace.tap`），各 tab 的栈留着，切走再切回来还停在原来那一页。
/// 几个栈一直挂着（不在前台的透明、点不到、读屏跳过，暂停订阅 `pageActive`）：切 tab 只换哪个露着，页不重建、不重排、不重画，滚动位置、没写完的字都在。
/// 没去过的 tab 打开 App 后安静一阵（`buildDelay`）再一个一个建（先读一份 `pagePrefetch`），第一次切过去也是现成的。推入、返回是系统的过渡，切 tab 原地换。
/// 被否决的：系统 `TabView` 藏起自带的标签栏、由这一排驱动——它每次换 tab 把切走的页摘出窗口（整页消失、挂回要重排重画，切一次多一倍的活），
/// 要靠把页藏回窗口的变通（依赖 UIKit 里 `UITab` 怎么管页）才省得下；底部附件（`tabViewBottomAccessory`）摆不出两格加 Cue 钮。
/// 推入的页上这一排照样在（同系统标签栏，写着灵感也能切去 Cue 看一眼），设置、技能与说明这类二级页让开（`Dock.stays`）。
/// Cue 页的输入框在页里（随键盘升起），底边那一格在换形里与 Cue 钮交叉，浓淡都是 `DockMotion.places` 的函数（`DockHandoff`）。打开 App 落在 Cue。
struct DockRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion: DockMotion
    /// 建过的 tab：建过就一直挂着。
    @State private var built: Set<Route> = []
    /// 在前台订阅的 tab：跟着 `Workspace.root`，等切过去的那一帧画上屏才换（同 Mac 的 `MacPages.leaving`）：
    /// 前后两个 tab 的订阅一停一起、实时状态一暂停一恢复要几十毫秒，不放在点击的回合里；页里的值本来就要等读库回来才更新。
    @State private var live: Route?

    init(workspace: Workspace) { _motion = State(initialValue: DockMotion(workspace: workspace)) }

    /// 打开 App 后先等这么久再建别的 tab：首屏、紧接着的滚动与输入不和它挤（同 Mac 启动后的预热）。
    private static let buildDelay: Duration = .seconds(2)

    var body: some View {
        let root = workspace.root, active = live ?? root
        ZStack {
            ForEach(Dock.tabs, id: \.self) { tab in
                if tab == root || built.contains(tab) {
                    let shown = tab == root
                    DockStack(tab: tab, active: active == tab)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                        .zIndex(shown ? 1 : 0)
                }
            }
        }
        .environment(\.dockMotion, motion)
        .overlay {
            // 底部那一排按窗口的宽在同一遍排版里排，不写回状态：打开时先按 0 宽排一遍，玻璃就多变一次形
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    PlacesCatcher(motion: motion, onCue: workspace.top == .cue) { openPlaces(false) }
                    DockBar(motion: motion, width: max(0, proxy.size.width - Dock.margin * 2), stays: stays, openPlaces: openPlaces)
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .debugExposesPlaces { openPlaces(true) }
        .onChange(of: root, initial: true) {
            built.insert(root)
            motion.placesOpen = false
            // 切走的 tab 留着、透明：它里面的输入框不交出焦点的话键盘还在、字还打进看不见的页里
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .task(id: root) {
            await NextFrame.drawn()
            if !Task.isCancelled { live = root }
        }
        .task {
            for tab in Dock.tabs {
                guard (try? await Task.sleep(for: Self.buildDelay)) != nil else { return }
                built.insert(tab)
            }
        }
        // 有焦点时"⋯"收起
        .onChange(of: motion.composing) { if motion.composing { openPlaces(false) } }
    }

    /// 浮起的输入框（新会话、发给 Agent）开着时底边归它，这一排让开：它落在这一排的位置上，留着就是两层玻璃叠着。
    private var stays: Bool { workspace.newSession == nil && workspace.outbox == nil && Dock.stays(on: workspace.top) }

    /// "⋯"展开、收起（点别处、滚动、点 Cue 钮、输入框有焦点时收起）：底部那一排用 `Motion.dock` 换形。
    private func openPlaces(_ open: Bool) {
        guard open != motion.placesOpen else { return }
        withAnimation(Motion.spatial(Motion.dock, reduceMotion: reduceMotion)) { motion.placesOpen = open }
    }
}

/// 一个 tab：根页自己画页顶那一排（系统导航栏只给推入的页，`HeaderHost.page`），内容一直滚到底部那一排后面（Cue 页的底边是它自己的输入框）。
private struct DockStack: View {
    let tab: Route
    let active: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let path = workspace[stack: tab]
        NavigationStack(path: Binding(get: { path }, set: { workspace[stack: tab] = $0 })) {
            RouteView(route: tab)
                .environment(\.headerHost, .page(search: Dock.search(on: tab)))
                .dockReserve(tab != .cue)
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { RouteView(route: $0).dockReserve(Dock.stays(on: $0)) }
        }
        .environment(\.pageActive, active)
        .environment(\.pagePrefetch, !active)
    }
}

/// 底部那一排此刻的样子：两格去处还是"⋯"加输入框只从这里推出来（`places`），底部那一排与 Cue 页的输入框读的是同一份。
@Observable
final class DockMotion {
    private let workspace: Workspace
    /// Cue 页底部的"⋯"展开成了两格（`DockRoot.openPlaces` 带着弹簧改）；换 tab 就收起。
    var placesOpen = false
    /// Cue 页的输入框有焦点：底部那一排让开、输入框占满整排。Cue 页在焦点进出时带着弹簧改（`CuePage`），
    /// 它与底部那一排各在一棵 SwiftUI 树里，读的是这同一份，所以输入框长宽与"⋯"淡出在同一次动画里。
    var composing = false

    init(workspace: Workspace) { self.workspace = workspace }

    /// 底部那一排是两格的样子占几成：1 是两格，0 是"⋯"加输入框（`DockHandoff`）。Cue 页的根上是后者；别的 tab、Cue 页上推入了页、"⋯"展开着是前者。
    var places: CGFloat { placesOpen || workspace.root != .cue || !workspace.path.isEmpty ? 1 : 0 }

    /// 选中的是 Cue：它的输入框在屏上。
    var onCue: Bool { workspace.root == .cue }

    /// 选中哪一格（`Dock.places` 的序号）；在 Cue 上时为 nil。
    var tab: Int? { Dock.places.firstIndex { $0.route == workspace.root } }
}

/// "⋯"展开时铺在 Cue 页上的一层：点一下或一划就收起。开合只重算这一小块。
private struct PlacesCatcher: View {
    let motion: DockMotion
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
    /// 三个 tab：两格去处与 Cue 钮。
    static let tabs: [Route] = places.map(\.route) + [.cue]

    /// 一格多宽：整排按格数分（每格去处一份、Cue 钮两份），中间不空；两格的胶囊与 Cue 钮差不多一样宽，不像缺了一格。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / CGFloat(places.count + 2)) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    /// tab 根页页顶那一排的搜索入口：项目页中间没有别的，是铺满的一条搜索框；进展页中间放着这一页看什么，是左边一颗圆钮；
    /// Cue 页的焦点就是 Cue，没有。提示横幅按它决定盖多宽（`NoticeBanner`）。
    static func search(on route: Route) -> HeaderSearch? {
        switch route {
        case .shelf: .field
        case .progress: .button
        default: nil
        }
    }

    /// 这一页上留不留着底部那一排：往下钻的页都留着（项目、灵感、会话……，换 tab 随时点得到）；设置、技能与说明这类二级页让开，同系统设置里的子页。
    static func stays(on route: Route) -> Bool {
        switch route {
        case .settings, .conflicts, .library, .libraryItem: false
        default: true
        }
    }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}
#endif

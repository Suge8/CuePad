#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：一个导航栈，根是当前去处的页（`HomePage`），推入的页照常由系统返回与左缘右滑回去。
/// 根只有底部那一排的四个去处（Cue、任务、会话、项目，`Route.home`），其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 四个根页都不用系统导航栏（藏起），顶上那一排是页自己画的（三页的搜索钮与右边那颗圆钮在 `floatingHeader` 里，Cue 页是页头）：
/// 换去处时两页在栈的根里水平推移（按底部那一排从左到右的顺序，`Dock.order`），推的是 SwiftUI 自己画的内容，逐帧插值；
/// 导航栈托管在 UIKit 里，挪整个栈（几个栈交替）时 SwiftUI 不逐帧挪它，旧页停着、最后一下才跳走，就是换去处时闪回旧页的那一下。
/// 先排后动（docs/ui.md 渲染性能）：新页先在屏外那一侧建好、画好、交出一帧，下一帧两页一起推（`arrived`）；底部那一排不跟着推，
/// 留在原处从旧的样子长成自己的（`Dock.Arrival`、`DockMove`）。推完才拿掉旧页，它这时已在屏外：
/// 位置只由 `arrived` 推出，拿掉时不回到原处。减弱动态效果时不推，新页在原处淡入。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    /// 屏上已经交给用户的去处：换去处时推完之前它还是旧的（出现前为 nil）。
    @State private var shown: Route?
    /// 推到了哪个去处：等于当前去处时新页在原处、旧页在屏外。
    @State private var arrived: Route?
    @State private var width: CGFloat = 0

    var body: some View {
        @Bindable var navigation = navigation
        let root = navigation.root
        let leaving = shown.flatMap { $0 == root ? nil : $0 }
        let settled = leaving == nil || arrived == root
        // 新页从哪一侧进来：去处在右边就从右边推进来
        let side: CGFloat = leaving.map { Dock.order($0) < Dock.order(root) ? 1 : -1 } ?? 0
        NavigationStack(path: $navigation.path) {
            ZStack {
                // 按去处认页：换去处时旧页留着推走，不重建。新页在上：它底部那一排停在原处，旧页推过去时不盖住它
                ForEach([leaving, root].compactMap(\.self), id: \.self) { route in
                    let current = route == root
                    let shift = reduceMotion ? 0 : (current ? (settled ? 0 : side) : (settled ? -side : 0)) * width
                    HomePage(route: route)
                        // 推着的两页各自铺满底色，不透出对方
                        .background(palette.desk)
                        .offset(x: shift)
                        .opacity(reduceMotion && current && !settled ? 0 : 1)
                        .allowsHitTesting(current)
                        .accessibilityHidden(!current)
                        .environment(\.dockMove, DockMove(settled: settled, leaving: !current && settled, shift: shift))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .onAppear {
            shown = root
            arrived = root
        }
        .onChange(of: root) {
            Task {
                await NextFrame.wait()
                withAnimation(reduceMotion ? Motion.crossfade : Motion.dock) {
                    arrived = navigation.root
                } completion: {
                    shown = navigation.root
                }
            }
        }
    }
}

/// 栈的根上的一个去处：它的页加底部一排。任务、会话、项目三页：底部是 `Dock`（推入的页上没有，它们有自己的底），
/// 顶上那一排左边一颗搜索钮、右边这一页的那一个操作，不写标题（`homePage`：底部的选中格已经说了在哪一页）；Cue 页：顶上是页头，
/// 底部的去处圆钮与输入框在它自己的页里（`CueDockRow`，输入框随键盘升起）。
private struct HomePage: View {
    let route: Route
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 安全区底边离屏幕底边多远（键盘弹出时是键盘高）。
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        RouteView(route: route)
            .environment(\.homePage, true)
            // 内容一直滚到 Dock 后面，最后一行停在 Dock 上面
            .safeAreaPadding(.bottom, route == .cue ? 0 : Dock.reserve(above: safeBottom))
            .overlay(alignment: .bottom) {
                // 不随键盘升起：键盘出来时盖住它
                if route != .cue {
                    Dock(route: route, arrival: reduceMotion ? nil : Dock.Arrival(from: navigation.previousRoot, to: route))
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
    }
}

/// 任务、会话、项目三页根上的底部一排：左边一块玻璃胶囊三格（`SidebarOutline` 的顺序：任务、会话、项目；图标在上字在下），
/// 右边一颗 Cue 圆钮（`CueDockButton`）。离屏幕左右与底边都是 21、高 62（与屏幕圆角同心，同系统悬浮标签栏），只是玻璃：
/// 栏后面不垫渐变或模糊，内容一直滚到它后面。选中那一格是一层中性淡墨的滴加靛青的图标与字（选中是一块底，docs/ui.md）。
/// 字号固定、不随动态字体放大，辅助字号下长按弹出大内容查看器（同系统标签栏：栏高固定，字放大只会挤掉图标）。
/// "项目"那一格在同步到不了 Mac 时带一个点（同设置那一行，`AppServices.macAlert`）。每格挂接力的落点（`relaySpot(dock:)`）。
///
/// 换去处的过渡（`Arrival`）：两页水平推移（`DockRoot`），这一排不跟着推，新页底部那一排从旧页那一排的样子长成自己的——从 Cue 页来时三格胶囊从左边那颗圆钮长开、
/// Cue 圆钮从输入框收回右端；去 Cue 页时反过来（`CueDockRow`）；三页之间换时滴从旧的那一格滑过来。新旧两排在两页里，
/// 各自按对方的位置（都是这里的常量）摆出第一帧，再用无回弹弹簧长到自己的样子；减弱动态效果时不换形，新页淡入。
struct Dock: View {
    /// 新去处的底部那一排从哪种样子长过来。
    enum Arrival {
        /// 从 Cue 页底部那一排（去处圆钮加输入框）。
        case fromCue
        /// 从三页之一：滴从那一格滑过来。
        case fromPlace(Route)
        /// 去 Cue 页：从 Dock 来。
        case fromDock

        init?(from previous: Route?, to route: Route) {
            guard let previous, previous != route else { return nil }
            switch (previous == .cue, route == .cue) {
            case (true, false): self = .fromCue
            case (false, true): self = .fromDock
            default: self = .fromPlace(previous)
            }
        }
    }

    /// 这一排所在的去处（选中那一格）：读它而不读此刻的去处，换走时推走中的旧页还是它原来的样子。
    let route: Route
    let arrival: Arrival?
    @Environment(Navigation.self) private var navigation
    /// 还在长成自己的样子之前的第一帧。
    @State private var arriving: Bool

    init(route: Route, arrival: Arrival?) {
        self.route = route
        self.arrival = arrival
        _arriving = State(initialValue: arrival != nil)
    }

    static let height: CGFloat = 62
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页圆钮与输入框之间的空。
    static let gap: CGFloat = 8
    /// Cue 页的输入框贴着安全区底边（键盘弹出时就是键盘顶）时离它的距离：窄屏输入框有焦点时、iPad 的 Cue 面板。
    static let keyboardGap: CGFloat = 8
    /// 选中滴离胶囊的边。
    static let inset: CGFloat = 4
    static let cellWidth: CGFloat = 76
    static let capsuleWidth = cellWidth * CGFloat(places.count) + inset * 2
    /// 三个去处，从左到右。
    static let places: [SidebarOutline.Entry] = [.tasks, .sessions, .allProjects]

    /// 四个去处在底部那一排里从左到右的位置（三格，Cue 在最右）：换去处时新页从它那一侧推进来（`DockRoot`）。
    static func order(_ route: Route) -> Int { places.firstIndex { $0.route == route } ?? places.count }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }

    var body: some View {
        let fromCue = arriving && isFromCue
        HStack(spacing: 0) {
            capsule(collapsed: fromCue)
            // 中间的空只在两块都是 Dock 的样子时撑开：Cue 圆钮还是输入框那么宽时它占满剩下的
            Spacer(minLength: Self.gap).frame(maxWidth: fromCue ? Self.gap : .infinity)
            CueDockButton(stretched: fromCue)
        }
        .padding(.horizontal, Self.margin)
        .modifier(Arrive(arriving: $arriving))
    }

    private var isFromCue: Bool { if case .fromCue = arrival { true } else { false } }

    /// 滴在哪一格：刚从三页之一来时先在那一格。
    private var dropIndex: Int? {
        if arriving, case .fromPlace(let previous) = arrival, let index = Self.places.firstIndex(where: { $0.route == previous }) { return index }
        return Self.places.firstIndex { $0.route == route }
    }

    /// `collapsed`：还是 Cue 页左边那颗圆钮的样子（刚从 Cue 页来的第一帧）。
    private func capsule(collapsed: Bool) -> some View {
        Capsule().fill(.clear)
            .frame(width: collapsed ? DockPlaces.size : Self.capsuleWidth, height: collapsed ? DockPlaces.size : Self.height)
            .overlay(alignment: .leading) {
                if let index = dropIndex {
                    DockDrop().frame(width: Self.cellWidth).padding(.vertical, Self.inset)
                        .offset(x: Self.inset + Self.cellWidth * CGFloat(index))
                }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Self.places, id: \.self) { place in
                        DockCell(place: place, selected: place.route == route) { navigation.select(place.route) }
                            .frame(width: Self.cellWidth)
                    }
                }
                .padding(.horizontal, Self.inset)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isTabBar)
            }
            .opacity(collapsed ? 0 : 1)
            .clipShape(.capsule)
            .glass(in: .capsule, interactive: true, ink: .clear)
    }
}

/// 选中那一格的滴：中性淡墨，浅色压暗、深色提亮一层，同系统标签栏。
private struct DockDrop: View {
    @Environment(\.palette) private var palette

    var body: some View { Capsule().fill(palette.fill) }
}

/// 一格去处：图标在上字在下（Cue 页展开的三格同一种）。选中时图标点睛与字是靛青。
private struct DockCell: View {
    let place: SidebarOutline.Entry
    let selected: Bool
    let action: () -> Void
    private static let icon: CGFloat = 20
    private static let label: CGFloat = 11
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                IconImage(place.dockIcon, accent: selected ? .lit : .none)
                    .font(.system(size: Self.icon, weight: selected ? .semibold : .medium))
                    .frame(height: Self.icon + 4)
                    .overlay(alignment: .topTrailing) { if place == .allProjects { syncDot } }
                Text(place.dockTitle).font(.system(size: Self.label, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? palette.signature : palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .relaySpot(dock: place)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.dockTitle)
        .accessibilityValue(services.macAlert.flatMap { place == .allProjects ? $0.title : nil } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityShowsLargeContentViewer { Label { Text(place.dockTitle) } icon: { Image(place.dockIcon) } }
    }

    @ViewBuilder private var syncDot: some View {
        if let alert = services.macAlert {
            Circle().fill(palette.color(alert.tone)).frame(width: 7, height: 7).offset(x: 4, y: -1).accessibilityHidden(true)
        }
    }
}

/// Dock 右边的 Cue：玻璃圆钮里是它的头像（表情、在跑的环、等你的赭黄环，`CueAvatar`）；点它去 Cue 页。iPhone 上 Cue 的新消息只提示在这里
/// （推入的页没有 Dock、不另提示，回到根页就看见）：又来一句时头像外漾一圈（`CueArrival`，同侧栏的 Cue 一行），右上角等你时是"等你"的数
/// （`WaitingBadge`），没有等你、有新消息时是石绿的点（`CueDot`）；读屏先说新消息。事实只读 `CueWatch.unread`、`waiting`。
/// 接力里它就是 Cue 那一头（`relaySpot(cue: .entry)`）：三页上没有页头，叫醒的光落在这里。
/// `stretched`：还是 Cue 页输入框的样子（刚从 Cue 页来的第一帧），头像在右端。
private struct CueDockButton: View {
    let stretched: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let cue = workspace.cue
        Button { navigation.select(.cue) } label: {
            CueAvatar(mood: cue.mood(composing: false), presence: cue.presence, size: .header)
                .background { CueArrival(color: palette.replied, reach: 1.5) }
                .relaySpot(cue: .entry)
                .frame(width: Dock.height, height: Dock.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .frame(maxWidth: stretched ? .infinity : Dock.height, alignment: .trailing)
        .frame(height: stretched ? DockPlaces.size : Dock.height)
        .glass(in: .capsule, interactive: true, ink: .clear)
        .overlay(alignment: .topTrailing) {
            Group {
                if cue.waiting > 0 {
                    WaitingBadge(count: cue.waiting).dynamicTypeSize(...DynamicTypeSize.xLarge).offset(x: 2, y: -2)
                } else {
                    CueDot().offset(x: -6, y: 6)
                }
            }
            .opacity(stretched ? 0 : 1)
            .animation(Motion.quick, value: cue.waiting)
        }
        .accessibilityLabel(cue.name)
        .accessibilityValue(cue.unread > 0 ? "\(cue.unread) 条新消息" : cue.waiting > 0 ? "等你 \(cue.waiting)" : "")
    }
}

/// Cue 页底部那一排（窄屏）：左边去处圆钮（`DockPlaces`，输入框有焦点时让开，输入框占满整排），右边输入框。
/// 去处展开时这一排就是三页上 Dock 的样子：左边三格带字，输入框收成右端一颗同 Cue 圆钮大小的圆（`FoldedComposer`），点它收回成输入框。
/// 从三页来时第一帧是 Dock 的样子——圆钮还是三格胶囊那么宽、输入框还是右端那颗 Cue 圆钮——再长成自己的（`Dock.Arrival`）。
struct CueDockRow<Composer: View>: View {
    @Binding var placesOpen: Bool
    let composing: Bool
    @ViewBuilder let composer: Composer
    @State private var arriving: Bool

    init(placesOpen: Binding<Bool>, composing: Bool, arrival: Dock.Arrival?, @ViewBuilder composer: () -> Composer) {
        _placesOpen = placesOpen
        self.composing = composing
        self.composer = composer()
        _arriving = State(initialValue: arrival != nil)
    }

    var body: some View {
        // 还是 Dock 的样子（刚从三页来，或去处展开着）：中间的空撑开，右端是一颗圆
        let docked = arriving || placesOpen
        HStack(alignment: .bottom, spacing: 0) {
            if !composing {
                DockPlaces(open: $placesOpen, docked: arriving).transition(.opacity)
                Spacer(minLength: Dock.gap).frame(maxWidth: docked ? .infinity : Dock.gap)
            }
            if placesOpen {
                FoldedComposer(unfold: $placesOpen).transition(.opacity)
            } else {
                composer.frame(maxWidth: arriving ? Dock.height : .infinity).transition(.opacity)
            }
        }
        .modifier(Arrive(arriving: $arriving))
        .onChange(of: composing) { if composing { placesOpen = false } }
    }
}

/// Cue 页底部左边那颗玻璃圆钮（与输入框同高）：图标是"⋯"（更多去处，不随上次去了哪页变）。点它原地展开成 Dock 那样的三格胶囊
/// （同宽同高，输入框收成右端一颗圆，`CueDockRow`），选一格就去那里；点别处、滚动或点那颗圆收回（`CuePage` 在对话上铺一层接点按）。
/// 接力的落点之一（`relaySpot(dock: nil)`）。
/// `docked`：还是 Dock 三格胶囊的样子（刚从三页来的第一帧）。
/// 圆钮与三格一直都在、只换不透明度，靠左叠着（玻璃往右长，三格不跟着挪）：先后换、不叠着交叉淡（`Motion.handOff`）——
/// 换出去的那样先淡完，换进来的晚这么久再出；插入、移除的过渡里被移除的那个随弹簧慢慢淡，"⋯"会叠在"任务"上停一阵。
struct DockPlaces: View {
    @Binding var open: Bool
    var docked = false
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = ComposerMetrics.slot

    /// 换进来（`entering`）的晚 `handOff` 再淡入，换出去的在 `handOff` 内淡完。
    private static func handOff(in entering: Bool) -> Animation {
        entering ? Motion.quick.delay(Motion.handOff) : .easeOut(duration: Motion.handOff)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Dock.places, id: \.self) { place in
                    DockCell(place: place, selected: false) {
                        open = false
                        navigation.select(place.route)
                    }
                    .frame(width: Dock.cellWidth)
                }
            }
            .padding(.horizontal, Dock.inset)
            .frame(width: Dock.capsuleWidth)
            .opacity(open ? 1 : 0)
            .animation(Self.handOff(in: open), value: open)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            Button { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { open = true } } label: {
                IconImage(.more).font(.system(size: 20, weight: .medium))
                    .frame(width: Self.size, height: Self.size)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(.button))
            .relaySpot(dock: nil)
            .accessibilityLabel("去处")
            .accessibilityHint("展开任务、会话、项目")
            .opacity(open || docked ? 0 : 1)
            .animation(Self.handOff(in: !open), value: open)
            .allowsHitTesting(!open)
            .accessibilityHidden(open)
        }
        .frame(width: docked || open ? Dock.capsuleWidth : Self.size, height: docked || open ? Dock.height : Self.size, alignment: .leading)
        .clipShape(.capsule)
        .glass(in: .capsule, interactive: true, ink: .clear)
    }
}

/// 去处展开时收起的输入框：右端一颗同 Cue 圆钮大小的玻璃圆，里面是 Cue 的头像（表情、在跑的环），点它收回成输入框。
/// 有草稿时头像是在听的表情，右上角挂一颗你的话那种牛皮纸色的小气泡（`Palette.bubble` 加 `Icon.said`，同你在对话里说的话）：
/// 草稿是你还没说出口的话，不借状态色。
private struct FoldedComposer: View {
    @Binding var unfold: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let badge: CGFloat = 20

    var body: some View {
        let cue = workspace.cue
        let drafted = !cue.draft.isEmpty(accepting: .images)
        Button { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { unfold = false } } label: {
            CueAvatar(mood: cue.mood(composing: drafted), presence: cue.presence, size: .header)
                .frame(width: Dock.height, height: Dock.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .glass(in: .circle, interactive: true, ink: .clear)
        .overlay(alignment: .topTrailing) {
            if drafted {
                IconImage(.said).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink)
                    .frame(width: Self.badge, height: Self.badge)
                    .background(palette.bubble, in: .circle)
                    .offset(x: 2, y: -2)
                    .transition(.opacity)
            }
        }
        .accessibilityLabel(cue.canHear ? "对 \(cue.name) 说" : "记一条灵感")
        .accessibilityValue(drafted ? "有草稿" : "")
        .accessibilityHint("收起去处，回到输入框")
    }
}

extension SidebarOutline.Entry {
    /// 底部那一排里的叫法：书架在窄屏就是"项目"那一页。
    var dockTitle: String { self == .allProjects ? "项目" : title }
    var dockIcon: Icon { self == .allProjects ? .projects : icon }
}

/// 换去处时一页底部那一排怎么动（`DockRoot` 按页给出）。新页建好那一帧 `settled` 还是 false：新的那一排第一帧停在旧的样子上；
/// 两页开始推时为 true，新的那一排从旧的样子长成自己的（`Motion.dock`），旧的那一排同一刻当场隐去（`leaving`），不随旧页推走。
/// 这一排不跟着页推：反着挪回页推出去的那一段（`shift`），与页同一个动画，停在原处原地换形。
struct DockMove {
    var settled = true
    var leaving = false
    var shift: CGFloat = 0
}

private struct Arrive: ViewModifier {
    @Binding var arriving: Bool
    @Environment(\.dockMove) private var move

    func body(content: Content) -> some View {
        content
            .offset(x: -move.shift)
            .opacity(move.leaving ? 0 : 1)
            .animation(nil, value: move.leaving)
            .onChange(of: move.settled, initial: true) {
                guard move.settled, arriving else { return }
                withAnimation(Motion.dock) { arriving = false }
            }
    }
}

extension EnvironmentValues {
    @Entry var dockMove = DockMove()
}
#endif

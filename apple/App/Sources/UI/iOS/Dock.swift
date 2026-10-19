#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：以当前去处为根的导航栈（`HomePage`），推入的页照常由系统返回与左缘右滑回去。
/// 根只有底部那一排的四个去处（Cue、任务、会话、项目，`Route.home`），其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 每个去处一个导航栈，换去处就换一个：导航栏的样子（Cue 页藏起、三页的大标题与搜索钮）在建出时就定好，不在同一个栈里换——
/// 同一个栈里从藏起导航栏的 Cue 页换到大标题的页，新页的滚动位置停在没有大标题的位置，大标题一出来就是收起的。
/// 换去处的过渡先排后动（docs/ui.md 渲染性能）：新栈先垫在旧栈下面建好、画好、交出一帧，下一帧旧栈才淡出，新页底部那一排同时从旧的样子长成自己的
/// （`Dock.Arrival`、`dockSettled`）；新页第一次建、画要上百毫秒，边建边动的话弹簧一开始就走完了大半。不透明度为 0 的新栈不画，所以垫在下面而不是透明着。
/// 旧栈的淡出是改它的不透明度、淡完再拿掉：导航栈托管在 UIKit 里，拿掉时的过渡不播。减弱动态效果时只淡出旧栈。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 屏上已经交给用户的去处：换去处时新去处先垫在下面建好一帧，这期间它还是旧的（出现前为 nil）。
    @State private var shown: Route?
    /// 换去处时旧栈推入的页，淡出时停在那一刻。
    @State private var leavingPath: [Route] = []
    /// 旧栈在淡出（新栈已建好一帧）。
    @State private var fading = false

    var body: some View {
        let root = navigation.root
        let leaving = shown.flatMap { $0 == root ? nil : $0 }
        ZStack {
            // 按去处认栈：换去处时旧栈挪到上面淡出，不重建
            ForEach([root, leaving].compactMap(\.self), id: \.self) { route in
                let current = route == root
                NavigationStack(path: current ? Binding(get: { navigation.path }, set: { navigation.path = $0 }) : .constant(leavingPath)) {
                    HomePage(route: route).navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
                .opacity(!current && fading ? 0 : 1)
                .allowsHitTesting(current)
            }
        }
        .onAppear { shown = root }
        // 与新栈同一次更新里就是 false：新页底部那一排的第一帧停在旧的样子上
        .environment(\.dockSettled, leaving == nil || fading)
        // 看根连同推入的页：换去处时旧栈停在换走前那一刻
        .onChange(of: [root] + navigation.path) { old, new in
            guard let from = old.first, from != new.first else { return }
            if shown == from { leavingPath = Array(old.dropFirst()) }
            fading = false
            Task {
                await NextFrame.wait()
                // 旧栈淡得比底部那一排长得快：它盖在上面，淡得慢就把形变遮住了
                withAnimation(reduceMotion ? Motion.crossfade : Motion.quick) {
                    fading = true
                } completion: {
                    shown = navigation.root
                    fading = false
                }
            }
        }
    }
}

/// 导航栈的根：一个去处的页加底部一排。任务、会话、项目三页：底部是 `Dock`（推入的页上没有，它跟着根页滑走，它们有自己的底），
/// 导航栏左边一颗搜索钮，系统大标题（`RouteView.home`）；Cue 页：导航栏藏起（根页不需要返回），底部的去处圆钮与输入框在它自己的页里
/// （`CueDockRow`，输入框随键盘升起）。
private struct HomePage: View {
    let route: Route
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 安全区底边离屏幕底边多远：随键盘（`keyboard`，键盘弹出时是键盘高）与不随键盘（`screen`，就是 Home 指示条那一段）。
    @State private var keyboard: CGFloat = 0
    @State private var screen: CGFloat = 0

    var body: some View {
        RouteView(route: route, home: route != .cue)
            // 内容一直滚到 Dock 后面，最后一行停在 Dock 上面
            .safeAreaPadding(.bottom, route == .cue ? 0 : Dock.reserve(above: keyboard))
            .overlay(alignment: .bottom) {
                // 不随键盘升起：键盘出来时盖住它
                if route != .cue {
                    Dock(arrival: reduceMotion ? nil : Dock.Arrival(from: navigation.previousRoot, to: route))
                        .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
                }
            }
            .toolbar {
                if route != .cue {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("搜索", icon: .search) { navigation.openSearch() }
                    }
                }
            }
            .toolbarVisibility(route == .cue ? .hidden : .visible, for: .navigationBar)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { keyboard = $0 }
            .background {
                Color.clear.ignoresSafeArea(.keyboard).onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { screen = $0 }
            }
            // Cue 页底部那一排离屏幕底边同 Dock；键盘弹出时贴着键盘（`CuePage`）
            .environment(\.dockLift, keyboard > screen ? Dock.keyboardGap : Dock.margin - screen)
    }
}

/// 任务、会话、项目三页根上的底部一排：左边一块玻璃胶囊三格（`SidebarOutline` 的顺序：任务、会话、项目；图标在上字在下），
/// 右边一颗 Cue 圆钮（`CueDockButton`）。离屏幕左右与底边都是 21、高 62（与屏幕圆角同心，同系统悬浮标签栏），只是玻璃：
/// 栏后面不垫渐变或模糊，内容一直滚到它后面。选中那一格是一层中性淡墨的滴加靛青的图标与字（选中是一块底，docs/ui.md）。
/// 字号固定、不随动态字体放大，辅助字号下长按弹出大内容查看器（同系统标签栏：栏高固定，字放大只会挤掉图标）。
/// "项目"那一格在同步到不了 Mac 时带一个点（同设置那一行，`AppServices.macAlert`）。每格挂接力的落点（`relaySpot(dock:)`）。
///
/// 换去处的过渡（`Arrival`）：两页交叉淡入淡出，新页底部那一排从旧页那一排的样子长成自己的——从 Cue 页来时三格胶囊从左边那颗圆钮长开、
/// Cue 圆钮从输入框收回右端；去 Cue 页时反过来（`CueDockRow`）；三页之间换时滴从旧的那一格滑过来。新旧两排在两个导航栈里，
/// 各自按对方的位置（都是这里的常量）摆出第一帧，再用无回弹弹簧长到自己的样子；减弱动态效果时只交叉淡入淡出。
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

    let arrival: Arrival?
    @Environment(Navigation.self) private var navigation
    /// 还在长成自己的样子之前的第一帧。
    @State private var arriving: Bool

    init(arrival: Arrival?) {
        self.arrival = arrival
        _arriving = State(initialValue: arrival != nil)
    }

    static let height: CGFloat = 62
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页圆钮与输入框之间的空。
    static let gap: CGFloat = 8
    /// 键盘弹出时 Cue 页那一排离键盘的距离。
    static let keyboardGap: CGFloat = 8
    /// 选中滴离胶囊的边。
    static let inset: CGFloat = 4
    private static let cellWidth: CGFloat = 76
    static let capsuleWidth = cellWidth * CGFloat(places.count) + inset * 2
    /// 三个去处，从左到右。
    static let places: [SidebarOutline.Entry] = [.tasks, .sessions, .allProjects]

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶到安全区底边）；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin - safeBottom) }

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
        return Self.places.firstIndex { $0.route == navigation.root }
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
                        DockCell(place: place, selected: place.route == navigation.root, size: .bar) { navigation.select(place.route) }
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

/// 一格去处：图标在上字在下（Cue 页展开的三格同一种，小一号）。选中时图标点睛与字是靛青。
private struct DockCell: View {
    enum Size {
        /// 三页底部的 Dock。
        case bar
        /// Cue 页那颗圆钮展开的三格。
        case inline

        var icon: CGFloat { self == .bar ? 20 : 18 }
        var label: CGFloat { self == .bar ? 11 : 10 }
    }

    let place: SidebarOutline.Entry
    let selected: Bool
    let size: Size
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                IconImage(place.dockIcon, accent: selected ? .lit : .none)
                    .font(.system(size: size.icon, weight: selected ? .semibold : .medium))
                    .frame(height: size.icon + 4)
                    .overlay(alignment: .topTrailing) { if place == .allProjects { syncDot } }
                Text(place.dockTitle).font(.system(size: size.label, weight: selected ? .semibold : .medium)).lineLimit(1)
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
        HStack(alignment: .bottom, spacing: 0) {
            if !composing {
                DockPlaces(open: $placesOpen, docked: arriving).transition(.opacity)
                // 中间的空只在还是 Dock 的样子时撑开（输入框还是右端那颗 Cue 圆钮）
                Spacer(minLength: Dock.gap).frame(maxWidth: arriving ? .infinity : Dock.gap)
            }
            composer.frame(maxWidth: arriving ? Dock.height : .infinity)
        }
        .modifier(Arrive(arriving: $arriving))
        .onChange(of: composing) { if composing { placesOpen = false } }
    }
}

/// Cue 页底部左边那颗玻璃圆钮（与输入框同高）：图标是上次去的那一页（`Navigation.lastPlace`）。点它原地展开成三格带字（输入框临时变窄），
/// 选一格就去那里；点别处或滚动收回（`CuePage` 在对话上铺一层接点按）。接力的落点之一（`relaySpot(dock: nil)`）。
/// `docked`：还是 Dock 三格胶囊的样子（刚从三页来的第一帧）。
struct DockPlaces: View {
    @Binding var open: Bool
    var docked = false
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = ComposerMetrics.slot
    private static let inset: CGFloat = 3
    private static let cellWidth: CGFloat = 56

    var body: some View {
        let last = Dock.places.first { $0.route == navigation.lastPlace } ?? .tasks
        ZStack {
            if open {
                HStack(spacing: 0) {
                    ForEach(Dock.places, id: \.self) { place in
                        DockCell(place: place, selected: false, size: .inline) {
                            open = false
                            navigation.select(place.route)
                        }
                        .frame(width: Self.cellWidth)
                    }
                }
                .padding(.horizontal, Self.inset)
                .transition(.opacity)
            } else {
                Button { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { open = true } } label: {
                    IconImage(last.dockIcon).font(.system(size: 20, weight: .medium))
                        .frame(width: Self.size, height: Self.size)
                        .contentShape(.circle)
                }
                .buttonStyle(PressStyle(.button))
                .relaySpot(dock: nil)
                .accessibilityLabel("去处")
                .accessibilityValue(last.dockTitle)
                .accessibilityHint("展开任务、会话、项目")
                .opacity(docked ? 0 : 1)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: docked ? Dock.height : Self.size)
        .glass(in: .capsule, interactive: true, ink: .clear)
    }

    private var width: CGFloat {
        if docked { return Dock.capsuleWidth }
        return open ? Self.cellWidth * CGFloat(Dock.places.count) + Self.inset * 2 : Self.size
    }
}

extension SidebarOutline.Entry {
    /// 底部那一排里的叫法：书架在窄屏就是"项目"那一页。
    var dockTitle: String { self == .allProjects ? "项目" : title }
    var dockIcon: Icon { self == .allProjects ? .projects : icon }
}

/// 新去处的栈建好、开始淡入时（`dockSettled`），底部那一排从旧的样子长成自己的，与淡入同一条弹簧。
private struct Arrive: ViewModifier {
    @Binding var arriving: Bool
    @Environment(\.dockSettled) private var settled

    func body(content: Content) -> some View {
        content.onChange(of: settled, initial: true) {
            guard settled, arriving else { return }
            withAnimation(Motion.snappy) { arriving = false }
        }
    }
}

extension EnvironmentValues {
    /// 窄屏当前去处的栈已经建好、在显示（`DockRoot`）：换去处时新栈先不显示地建好一帧，这之后底部那一排才开始长。
    @Entry var dockSettled = true
    /// Cue 页底部那一排离安全区底边的距离（负的是伸进 Home 指示条那一段，与 Dock 离屏幕底边一样远）。
    @Entry var dockLift: CGFloat = Dock.keyboardGap
}
#endif

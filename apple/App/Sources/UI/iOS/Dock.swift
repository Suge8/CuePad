#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：一个导航栈，根是当前去处的页（`HomePage`），推入的页照常由系统返回与左缘右滑回去。
/// 根只有底部那一排的四个去处（项目、任务、会话、Cue，`Route.home`），其余去处推在所属的那一页上（`Navigation.select`）；打开 App 落在 Cue。
/// 四个根页都不用系统导航栏（藏起），顶上那一排是页自己画的（三页的搜索钮与右边那颗圆钮在 `floatingHeader` 里，Cue 页是页头）：
/// 换去处时两页在栈的根里水平推移（按底部那一排从左到右的顺序，`Dock.order`），推的是 SwiftUI 自己画的内容，逐帧插值；
/// 导航栈托管在 UIKit 里，挪整个栈（几个栈交替）时 SwiftUI 不逐帧挪它，旧页停着、最后一下才跳走，就是换去处时闪回旧页的那一下。
/// 先排后动（docs/ui.md 渲染性能）：新页先在屏外那一侧建好、画好、交出一帧，下一帧两页一起推（`arrived`）。推完才拿掉旧页，它这时已在屏外：
/// 位置只由 `arrived` 推出，拿掉时不回到原处。减弱动态效果时不推，新页在原处淡入。
/// 底部那一排整个窗口只有一份（`DockBar`），挂在栈的根上、不在哪一页里：换去处时它不重建、不跟着推，与页同一条弹簧原地换形（`morph`）。
/// 每页各建一排时，新页那一排要从旧的样子摆出第一帧再长回来，"⋯"展开着换去处就是收成圆再长开的一下来回。
/// Cue 页的输入框在页里（随键盘升起），底边那一格同一时刻只有一个主人（`handed`）：换形一开始离开输入框的样子就交给 Cue 钮，
/// 长成输入框的那条弹簧做完（动画的完成回调）才交还给页里的输入框。不按延时交接：玻璃不跟延时的不透明度动画，当场就藏了。
/// 不用折叠的分栏：那个容器本身冷启动就多约 3000M 指令。
struct DockRoot: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    /// 屏上已经交给用户的去处：换去处时推完之前它还是旧的（出现前为 nil）。
    @State private var shown: Route?
    /// 推到了哪个去处：等于当前去处时新页在原处、旧页在屏外。
    @State private var arrived: Route?
    /// 底部那一排此刻画成的样子：跟着该有的样子（`DockLook.init`）换形，出现前为 nil。
    @State private var look: DockLook?
    /// 底边那一格交给了 Cue 页里的输入框；Cue 钮等输入框画上屏才藏起（`released`）。
    @State private var handed = false
    @State private var released = false
    @State private var width: CGFloat = 0

    var body: some View {
        @Bindable var navigation = navigation
        let root = navigation.root
        let leaving = shown.flatMap { $0 == root ? nil : $0 }
        let settled = leaving == nil || arrived == root
        // 新页从哪一侧进来：去处在右边就从右边推进来
        let side: CGFloat = leaving.map { Dock.order($0) < Dock.order(root) ? 1 : -1 } ?? 0
        let target = DockLook(route: arrived ?? root, navigation: navigation)
        NavigationStack(path: $navigation.path) {
            ZStack {
                // 按去处认页：换去处时旧页留着推走，不重建
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
                }
            }
            .environment(\.dockComposer, handed)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 推入的页盖住它
            .overlay(alignment: .bottom) {
                DockBar(route: arrived ?? root, look: look ?? target, released: released, width: max(0, width - Dock.margin * 2))
                    .padding(.bottom, Dock.margin).ignoresSafeArea(edges: .bottom)
            }
            // 推移是 SwiftUI 逐帧插值的位移，图层上看不出在动：截图要等旧页拿掉（推完）再拍，不然拍到两页各露一截
            .debugSettling(leaving != nil)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .onAppear {
            shown = root
            arrived = root
        }
        .onChange(of: target, initial: true) { morph(to: target) }
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
/// （`homePage`：底部的选中格已经说了在哪一页），内容一直滚到底部那一排后面；Cue 页顶上是页头，输入框在它自己的页里（随键盘升起）。
private struct HomePage: View {
    let route: Route
    /// 安全区底边离屏幕底边多远（键盘弹出时是键盘高）。
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        RouteView(route: route)
            .environment(\.homePage, true)
            // 内容一直滚到 Dock 后面，最后一行停在 Dock 上面
            .safeAreaPadding(.bottom, route == .cue ? 0 : Dock.reserve(above: safeBottom))
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
    }
}

/// 底部那一排的尺寸与顺序。
enum Dock {
    static let height: CGFloat = 62
    static let margin: CGFloat = 21
    /// 两块玻璃之间、Cue 页"⋯"与输入框之间的空。
    static let gap: CGFloat = 8
    /// 选中滴离胶囊的边。
    static let inset: CGFloat = 4
    /// Cue 页上收起时那颗"⋯"（与输入框同高）。
    static let slot = ComposerMetrics.slot
    /// 一格最宽：宽的窄窗口（iPad）里格子不再长，多出来的给 Cue 钮。
    static let maxCell: CGFloat = 76
    /// 三个去处，从左到右：项目、任务、会话（会话挨着 Cue：接力的光从 Cue 落到它那一格最近）。
    static let places: [SidebarOutline.Entry] = [.allProjects, .tasks, .sessions]

    /// 一格多宽：整排按五格分（三格去处、两格 Cue），中间不空。
    static func cell(in width: CGFloat) -> CGFloat { min(maxCell, (width - gap - inset * 2) / 5) }
    static func capsule(in width: CGFloat) -> CGFloat { cell(in: width) * CGFloat(places.count) + inset * 2 }

    /// 四个去处在底部那一排里从左到右的位置（三格，Cue 在最右）：换去处时新页从它那一侧推进来（`DockRoot`）。
    static func order(_ route: Route) -> Int { places.firstIndex { $0.route == route } ?? places.count }

    /// 内容在安全区之上还要给 Dock 让出的高度（栏顶再隔 `Bars.contentGap` 到安全区底边）：滚到底时最后一行完整停在栏上面；键盘盖住 Dock 时为 0。
    static func reserve(above safeBottom: CGFloat) -> CGFloat { max(0, height + margin + Bars.contentGap - safeBottom) }
}

/// 底部那一排该是什么样子：三页上与 Cue 页点开"⋯"时是三格，Cue 页上是"⋯"加输入框，输入框有焦点时都让开。
enum DockLook {
    case places, cue, composing

    init(route: Route, navigation: Navigation) {
        guard route == .cue, !navigation.placesOpen else {
            self = .places
            return
        }
        self = navigation.cueComposing ? .composing : .cue
    }
}

/// 底部那一排：左边一块玻璃，右边 Cue 钮，按此刻的样子（`DockLook`）原地换形，不换身份。
/// - 三页上、Cue 页点开"⋯"时（`.places`）：左边三格胶囊（图标在上字在下，选中那一格是一层中性淡墨的滴加靛青的图标与字），右边 Cue 钮占两格宽（`DockCue`）。
/// - Cue 页（`.cue`）：左边收成一颗"⋯"（与输入框同高），Cue 钮长成输入框那么宽、那么高，交给页里真的输入框（`DockRoot.handed`）。
/// - Cue 页输入框有焦点（`.composing`）：都让开，输入框占满整排。
/// 三页之间换只是滴滑到新那一格；Cue 页点开"⋯"本来就是三页的样子，选一格去那里什么都不换形。离屏幕左右与底边都是 21、高 62
/// （与屏幕圆角同心，同系统悬浮标签栏），只是玻璃：栏后面不垫渐变或模糊。字号固定、不随动态字体放大，辅助字号下长按弹出大内容查看器
/// （同系统标签栏：栏高固定，字放大只会挤掉图标）。"项目"那一格在同步到不了 Mac 时带一个点（`AppServices.macAlert`）。
/// 接力的"会话"那一头（`relaySpot(dock:)`）：三格展开时是"会话"那一格，收起时是"⋯"。减弱动态效果时不换形，直接到新样子。
private struct DockBar: View {
    /// 推到了哪个去处（`DockRoot` 在推移的动画里改它，选中的滴与页同一个动画滑过去）。
    let route: Route
    let look: DockLook
    /// 底边那一格交给了页里的输入框、它已画上屏：Cue 钮藏起。
    let released: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let places = look == .places
        let left = places ? Dock.capsule(in: width) : Dock.slot
        let height = places ? Dock.height : Dock.slot
        ZStack(alignment: .bottomLeading) {
            DockPlaces(route: route, open: places, cell: Dock.cell(in: width))
                .frame(width: left, height: height, alignment: .leading)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true, ink: .clear)
                .opacity(look == .composing ? 0 : 1)
                .allowsHitTesting(look != .composing)
            DockCue(places: places)
                .frame(width: max(0, width - left - Dock.gap), height: height)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true, ink: .clear)
                .offset(x: left + Dock.gap)
                .opacity(released ? 0 : 1)
                .allowsHitTesting(places)
                .accessibilityHidden(!places)
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// 左边那块玻璃的内容：三格与"⋯"一直都在、只换不透明度，靠左叠着（玻璃往右长，三格不跟着挪）：先后换、不叠着交叉淡（`Motion.handOff`）——
/// 换出去的那样先淡完，换进来的晚这么久再出；插入、移除的过渡里被移除的那个随弹簧慢慢淡，"⋯"会叠在"项目"上停一阵。
private struct DockPlaces: View {
    let route: Route
    let open: Bool
    let cell: CGFloat
    @Environment(Navigation.self) private var navigation

    /// 换进来（`entering`）的晚 `handOff` 再淡入，换出去的在 `handOff` 内淡完。
    private static func handOff(in entering: Bool) -> Animation {
        entering ? Motion.quick.delay(Motion.handOff) : .easeOut(duration: Motion.handOff)
    }

    var body: some View {
        let selected = Dock.places.firstIndex { $0.route == route }
        ZStack(alignment: .leading) {
            Group {
                if let selected {
                    DockDrop().frame(width: cell).padding(.vertical, Dock.inset)
                        .offset(x: Dock.inset + cell * CGFloat(selected))
                        .transition(.opacity)
                }
                HStack(spacing: 0) {
                    ForEach(Dock.places, id: \.self) { place in
                        DockCell(place: place, selected: place.route == route, relays: open) { navigation.select(place.route) }
                            .frame(width: cell)
                    }
                }
                .padding(.horizontal, Dock.inset)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isTabBar)
            }
            .frame(height: Dock.height)
            .opacity(open ? 1 : 0)
            .animation(Self.handOff(in: open), value: open)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
            Button { navigation.placesOpen = true } label: {
                IconImage(.more).font(.system(size: 20, weight: .medium))
                    .frame(width: Dock.slot, height: Dock.slot)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(.button))
            .relaySpot(dock: !open)
            .accessibilityLabel("去处")
            .accessibilityHint("展开项目、任务、会话")
            .opacity(open ? 0 : 1)
            .animation(Self.handOff(in: !open), value: open)
            .allowsHitTesting(!open)
            .accessibilityHidden(open)
        }
    }
}

/// 选中那一格的滴：中性淡墨，浅色压暗、深色提亮一层，同系统标签栏。
private struct DockDrop: View {
    @Environment(\.palette) private var palette

    var body: some View { Capsule().fill(palette.fill) }
}

/// 一格去处：图标在上字在下。选中时图标点睛与字是靛青。
private struct DockCell: View {
    let place: SidebarOutline.Entry
    let selected: Bool
    /// 三格展开着："会话"那一格是接力的落点。
    let relays: Bool
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
        .relaySpot(dock: relays && place == .sessions)
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

/// 底部那一排右边的 Cue 钮：占两格宽，右端是它的头像（表情、在跑的环、等你的赭黄环，`CueAvatar`；又来一句时外漾一圈 `CueArrival`），
/// 左边两行"推进中 N"、"等你 M"（`DockTally`）；点它去 Cue 页。iPhone 上 Cue 的新消息只提示在这里（推入的页没有这一排、不另提示）：
/// 头像右上角石绿的点（`CueDot`）；有没说出去的草稿时那里是一颗牛皮纸色的小气泡（同你说的话，`Palette.bubble` 加 `Icon.said`）。
/// 在 Cue 页上它长成输入框那么宽、那么高（头像落在输入框右端头像的位置），交给页里真的输入框；离开时反过来从输入框缩回来。
/// 接力里它就是 Cue 那一头（`CueSpot.dock`）：三页上没有页头，光落在这里。
private struct DockCue: View {
    /// 是三格那种样子（不是长成输入框）。
    let places: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(Navigation.self) private var navigation

    private static let badge: CGFloat = 20

    var body: some View {
        let cue = workspace.cue
        let drafted = !cue.draft.isEmpty(accepting: .images)
        Button(action: open) {
            HStack(spacing: 0) {
                DockTally()
                    .padding(.leading, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CueAvatar(mood: cue.mood(composing: drafted), presence: cue.presence, size: .header)
                    .background { CueArrival(color: palette.replied, reach: 1.5) }
                    .relaySpot(cue: .dock)
                    .frame(width: Dock.height)
                    .overlay(alignment: .topTrailing) { corner(drafted: drafted) }
            }
            // 长成输入框时里面先淡掉，只剩玻璃在长，长到了交给页里的输入框
            .animation(.easeOut(duration: Motion.handOff)) {
                $0.opacity(places ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cue.name)
        .accessibilityValue(Dotted(cue.unread > 0 ? "\(cue.unread) 条新消息" : nil, DockTally.spoken(cue), drafted ? "有草稿" : nil).spoken)
    }

    /// 在 Cue 页上（"⋯"展开着）点它是收起、回到输入框；在三页上是去 Cue 页。
    private func open() {
        guard navigation.root != .cue else {
            navigation.placesOpen = false
            return
        }
        navigation.select(.cue)
    }

    @ViewBuilder private func corner(drafted: Bool) -> some View {
        Group {
            if workspace.cue.unread > 0 {
                CueDot().offset(x: -10, y: 6)
            } else if drafted {
                IconImage(.said).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink)
                    .frame(width: Self.badge, height: Self.badge)
                    .background(palette.bubble, in: .circle)
                    .offset(x: -2, y: -4)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: drafted)
    }
}

/// Cue 钮左边的两行：上"推进中 N"（次要墨色），下"等你 M"（`WaitingCount`，赭黄）；为 0 的那行不写，都为 0 写一句安静的现状。
/// 两个数就是 Cue 此刻的（`CueNow.advancing`、`CueWatch.waiting`，都出自 `CueStore.cueTally`），不另算。数变了原地滚过去。
private struct DockTally: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static func spoken(_ cue: CueWatch) -> String {
        guard cue.now.advancing > 0 || cue.waiting > 0 else { return CueNow.quiet }
        return Dotted(cue.now.advancing > 0 ? "推进中 \(cue.now.advancing)" : nil, cue.waiting > 0 ? "等你 \(cue.waiting)" : nil).spoken
    }

    var body: some View {
        let cue = workspace.cue
        VStack(alignment: .leading, spacing: 2) {
            if cue.now.advancing > 0 {
                Text("推进中 \(cue.now.advancing)").monospacedDigit().foregroundStyle(palette.ink2)
                    .contentTransition(.numericText(value: Double(cue.now.advancing)))
            }
            WaitingCount(count: cue.waiting)
            if cue.now.advancing == 0, cue.waiting == 0 {
                Text(CueNow.quiet).foregroundStyle(palette.ink3)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
        .animation(Motion.quick, value: cue.now.advancing)
        .animation(Motion.quick, value: cue.waiting)
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
}
#endif

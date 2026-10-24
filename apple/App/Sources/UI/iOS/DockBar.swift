#if os(iOS)
import SwiftUI

/// 底部那一排：左边一块玻璃，右边 Cue 钮，原地换形，不换身份。样子是连续的，跟着根上那一条（`PagerMotion`）走，拖到哪长到哪：
/// - 项目、进展两页上、Cue 页点开"⋯"时：左边两格胶囊，右边 Cue 钮（`DockCue`）。选中的滴（`DockDrop`）跟着条在两格间滑，透过它的那一格着靛青。
/// - Cue 页：左边收成一颗"⋯"，Cue 钮长成输入框那么宽、那么高，在换形里与页里真的输入框交叉（`DockHandoff`）。从进展页滑向 Cue 页时跟着手指一点点长过去。
/// - Cue 页输入框有焦点（`PagerMotion.composing`）：都让开，输入框占满整排。
/// 与屏幕圆角同心（同系统悬浮标签栏），只是玻璃：栏后面不垫渐变或模糊。字号固定、不随动态字体放大，辅助字号下长按弹出大内容查看器
/// （同系统标签栏：栏高固定，字放大只会挤掉图标）。"项目"那一格在同步到不了 Mac 时带一个点（`AppServices.macAlert`）。
/// 接力的"会话"那一头（`relaySpot(dock:)`）只在两格展开时的"进展"那一格（会话在进展里）；收起的"⋯"不接力：光落进"⋯"读不出是去了哪，深色下只剩一团发光的靛青点。
/// 减弱动态效果时不换形，直接到新样子（条那边也不滑）。
struct DockBar: View {
    /// 当前去处（`Workspace.root`）：读屏的选中、点 Cue 钮是去 Cue 页还是收起"⋯"。
    let route: Route
    let motion: PagerMotion
    let width: CGFloat
    let openPlaces: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DockForm(places: motion.places, route: route, motion: motion, composing: motion.composing, width: width, openPlaces: openPlaces)
            .animation(Motion.dock, value: motion.composing)
            .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// 换形的每一帧都从 `places` 算（`Animatable`）：点按时弹簧逐帧插的是它，不是首尾两个样子之间直线过渡，各段浓淡与拖动时一样（`DockHandoff`）。
private struct DockForm: View, Animatable {
    var places: CGFloat
    let route: Route
    let motion: PagerMotion
    let composing: Bool
    let width: CGFloat
    let openPlaces: (Bool) -> Void

    var animatableData: CGFloat {
        get { places }
        set { places = newValue }
    }

    var body: some View {
        let shown = places > 0.5
        let left = Dock.slot + (Dock.capsule(in: width) - Dock.slot) * places
        let height = Dock.slot + (Dock.height - Dock.slot) * places
        ZStack(alignment: .bottomLeading) {
            DockPlaces(motion: motion, route: route, places: places, cell: Dock.cell(in: width)) { openPlaces(true) }
                .frame(width: left, height: height, alignment: .leading)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true, ink: .clear)
                .opacity(composing ? 0 : 1)
                .allowsHitTesting(!composing)
            DockCue(places: places) { openPlaces(false) }
                .frame(width: max(0, width - left - Dock.gap), height: height)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true, ink: .clear)
                .offset(x: left + Dock.gap)
                .opacity(DockHandoff.ramp(places, DockHandoff.cueGlass))
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
    }
}

/// 左边那块玻璃的内容：去处那几格与"⋯"一直都在、只换不透明度，靠左叠着（玻璃往右长，格子不跟着挪）。
private struct DockPlaces: View {
    let motion: PagerMotion
    let route: Route
    /// 去处那几格的样子占几成（`DockBar`）。
    let places: CGFloat
    let cell: CGFloat
    let expand: () -> Void

    var body: some View {
        let open = places > 0.5
        ZStack(alignment: .leading) {
            DockCells(position: motion.position, onCue: motion.onCue, route: route, cell: cell, relays: open)
                .opacity(DockHandoff.ramp(places, DockHandoff.cells))
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
            Button(action: expand) {
                IconImage(.more).font(.system(size: 20, weight: .medium))
                    .frame(width: Dock.slot, height: Dock.slot)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(.button))
            .accessibilityLabel("去处")
            .accessibilityHint("展开项目、进展")
            .opacity(1 - DockHandoff.ramp(places, DockHandoff.more))
            .allowsHitTesting(!open)
            .accessibilityHidden(open)
        }
    }
}

/// 去处那几格与滴，每一帧都从条的位置算（`Animatable`）：拖动时跟手，点按、松手的弹簧逐帧插的是位置，滴与透过它着色的格子才走在一起。
/// 格子画两遍：平常的墨色一遍（按钮，滴盖住的地方挖掉），选中的样子（图标点睛、字靛青、粗一档）一遍只露在滴里，
/// 滴滑过哪里哪里就着色，两格之间时各着一半（同系统标签栏的选中跟着手指走）。每帧只挪滴与两层遮罩，格子本身不重算。
private struct DockCells: View, Animatable {
    var position: CGFloat
    var onCue: CGFloat
    let route: Route
    let cell: CGFloat
    let relays: Bool
    @Environment(Workspace.self) private var workspace

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, onCue) }
        set { (position, onCue) = (newValue.first, newValue.second) }
    }

    var body: some View {
        let drop = DockDrop(position: position, onCue: onCue, cell: cell)
        ZStack(alignment: .leading) {
            DockDropShape(drop: drop)
            HStack(spacing: 0) {
                ForEach(Dock.places, id: \.self) { place in
                    DockCell(place: place, selected: place.route == route, relays: relays) { workspace.select(place.route) }
                        .frame(width: cell)
                }
            }
            .padding(.horizontal, Dock.inset)
            .mask { Rectangle().overlay { DropMask(drop: drop).blendMode(.destinationOut) }.compositingGroup() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
            HStack(spacing: 0) {
                ForEach(Dock.places, id: \.self) { DockCellLabel(place: $0, lit: true).frame(width: cell) }
            }
            .padding(.horizontal, Dock.inset)
            .mask { DropMask(drop: drop) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// 滴的轮廓（遮罩用）。
private struct DropMask: View {
    let drop: DockDrop

    var body: some View {
        Capsule()
            .frame(width: drop.rect.width, height: drop.rect.height)
            .position(x: drop.rect.midX, y: drop.rect.midY)
            .opacity(drop.opacity)
    }
}

/// 选中的滴：一格宽的胶囊，停在条所在的那一格；条在两格之间时它也在两格之间，并拉长一点、压扁一点（像被拖着走的一滴水），停下缩回一格。
/// 条滑向 Cue 页时淡去（Cue 页没有选中的格）。位置都从 `PagerMotion.position` 算：拖动跟手，松手、点按与页同一条弹簧。
private struct DockDrop {
    /// 在去处那一排里的位置（左边的内边距算在里面）。
    let rect: CGRect
    let opacity: Double
    /// 拉长、压扁的最大比例（两格正中间时）。
    private static let stretch: CGFloat = 0.24
    private static let squash: CGFloat = 0.08

    init(position: CGFloat, onCue: CGFloat, cell: CGFloat) {
        let x = min(max(position, 0), CGFloat(Dock.places.count - 1))
        let between = sin(.pi * (x - x.rounded(.down)))
        let width = cell * (1 + Self.stretch * between)
        let height = (Dock.height - Dock.inset * 2) * (1 - Self.squash * between)
        rect = CGRect(x: Dock.inset + cell * (x + 0.5) - width / 2, y: (Dock.height - height) / 2, width: width, height: height)
        opacity = 1 - Double(onCue)
    }
}

/// 滴的样子：中性淡墨（浅色压暗、深色提亮一层，同系统标签栏），上沿一线高光、一圈发丝边，像玻璃里浮着的一片。
private struct DockDropShape: View {
    let drop: DockDrop
    @Environment(\.palette) private var palette

    var body: some View {
        Capsule().fill(palette.fill)
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [palette.sheen, palette.hair], startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .frame(width: drop.rect.width, height: drop.rect.height)
            .position(x: drop.rect.midX, y: drop.rect.midY)
            .opacity(drop.opacity)
            .allowsHitTesting(false)
    }
}

/// 一格去处：图标在上字在下（平常的那一遍，选中的样子在 `DockCells` 里另画一遍）。
private struct DockCell: View {
    let place: SidebarOutline.Entry
    /// 当前去处是它（读屏的选中）。
    let selected: Bool
    /// 两格展开着："进展"那一格是接力的落点。
    let relays: Bool
    let action: () -> Void
    @Environment(AppServices.self) private var services

    var body: some View {
        Button(action: action) {
            DockCellLabel(place: place, lit: false).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .relaySpot(dock: relays && place == .progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.title)
        .accessibilityValue(services.macAlert.flatMap { place == .projects ? $0.title : nil } ?? "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityShowsLargeContentViewer { Label { Text(place.title) } icon: { Image(place.icon) } }
    }
}

/// 一格的图标与字；`lit` 是选中的样子：图标点睛、字靛青、粗一档。
private struct DockCellLabel: View {
    let place: SidebarOutline.Entry
    let lit: Bool
    private static let icon: CGFloat = 20
    private static let label: CGFloat = 11
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 3) {
            IconImage(place.icon, accent: lit ? .lit : .none)
                .font(.system(size: Self.icon, weight: lit ? .semibold : .medium))
                .frame(height: Self.icon + 4)
                .overlay(alignment: .topTrailing) { if place == .projects { syncDot } }
            Text(place.title).font(.system(size: Self.label, weight: lit ? .semibold : .medium)).lineLimit(1)
        }
        .foregroundStyle(lit ? palette.signature : palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
/// 接力里它就是 Cue 那一头（`CueSpot.dock`）：项目、进展两页上没有页头，光落在这里。
private struct DockCue: View {
    /// 去处那几格的样子占几成（1 是展开，0 是长成输入框）。
    let places: CGFloat
    /// 在 Cue 页上（"⋯"展开着）点它是收起、回到输入框。
    let collapse: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

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
            // 长成输入框时里面先淡掉，只剩玻璃在长，与页里的输入框交叉
            .opacity(DockHandoff.ramp(places, DockHandoff.cue))
            .frame(maxHeight: .infinity)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cue.name)
        .accessibilityValue(Dotted(cue.unread > 0 ? "\(cue.unread) 条新消息" : nil, DockTally.spoken(cue), drafted ? "有草稿" : nil).spoken)
    }

    /// 在 Cue 页上（"⋯"展开着）点它是收起、回到输入框；在项目、进展页上是去 Cue 页。
    private func open() {
        guard workspace.root != .cue else {
            collapse()
            return
        }
        workspace.select(.cue)
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
        .animation(HandOff.quick, value: drafted)
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
        .animation(HandOff.quick, value: cue.now.advancing)
        .animation(HandOff.quick, value: cue.waiting)
    }
}
#endif

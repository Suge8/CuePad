#if os(iOS)
import SwiftUI

/// 底部那一排：左边一块玻璃，右边 Cue 钮，按此刻的样子（`DockLook`）原地换形，不换身份。
/// - 三页上、Cue 页点开"⋯"时（`.places`）：左边三格胶囊，右边 Cue 钮占两格宽（`DockCue`）。
/// - Cue 页（`.cue`）：左边收成一颗"⋯"，Cue 钮长成输入框那么宽、那么高，交给页里真的输入框（`DockRoot.handed`）。
/// - Cue 页输入框有焦点（`.composing`）：都让开，输入框占满整排。
/// 三页之间换只是滴滑到新那一格；Cue 页点开"⋯"本来就是三页的样子，选一格去那里什么都不换形。与屏幕圆角同心（同系统悬浮标签栏），只是玻璃：栏后面不垫渐变或模糊。字号固定、不随动态字体放大，辅助字号下长按弹出大内容查看器
/// （同系统标签栏：栏高固定，字放大只会挤掉图标）。"项目"那一格在同步到不了 Mac 时带一个点（`AppServices.macAlert`）。
/// 接力的"会话"那一头（`relaySpot(dock:)`）只在三格展开时的"会话"那一格；收起的"⋯"不接力：光落进"⋯"读不出是去了哪，深色下只剩一团发光的靛青点。
/// 减弱动态效果时不换形，直接到新样子。
struct DockBar: View {
    /// 当前去处（`Workspace.root`）：换了它，选中的滴与页同一刻滑过去。
    let route: Route
    let look: DockLook
    /// 底边那一格交给了页里的输入框、它已画上屏：Cue 钮藏起。
    let released: Bool
    @Binding var placesOpen: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let places = look == .places
        let left = places ? Dock.capsule(in: width) : Dock.slot
        let height = places ? Dock.height : Dock.slot
        ZStack(alignment: .bottomLeading) {
            DockPlaces(route: route, open: places, cell: Dock.cell(in: width)) { placesOpen = true }
                .frame(width: left, height: height, alignment: .leading)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true, ink: .clear)
                .opacity(look == .composing ? 0 : 1)
                .allowsHitTesting(look != .composing)
            DockCue(places: places) { placesOpen = false }
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
    let expand: () -> Void
    @Environment(Workspace.self) private var workspace

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
                        DockCell(place: place, selected: place.route == route, relays: open) { workspace.select(place.route) }
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
            Button(action: expand) {
                IconImage(.more).font(.system(size: 20, weight: .medium))
                    .frame(width: Dock.slot, height: Dock.slot)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle(.button))
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
/// 接力里它就是 Cue 那一头（`CueSpot.dock`）：三页上没有页头，光落在这里。
private struct DockCue: View {
    /// 是三格那种样子（不是长成输入框）。
    let places: Bool
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
#endif

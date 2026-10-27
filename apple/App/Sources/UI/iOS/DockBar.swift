#if os(iOS)
import SwiftUI

/// 底部那一排：左边两格去处（系统标签栏，`DockTabs`），右边 Cue 钮，原地换形，样子只从 `DockMotion.places` 推出来，换 tab 时带着 `Motion.travel` 换：
/// - 项目、进展两个 tab 上、Cue 页点开"⋯"时：左边两格，右边 Cue 钮（`DockCue`）。按住拖动的透镜是系统的。
/// - Cue 页：左边一颗"⋯"，Cue 钮长成输入框那么宽、那么高，在换形里与页里真的输入框交叉（`DockHandoff`）。
/// - Cue 页输入框有焦点（`DockMotion.composing`）：都让开，输入框占满整排。
/// - 推入的页上总是两格加 Cue 钮，点所在的那一格（或在 Cue 上时点 Cue 钮）回到那个 tab 的根上；二级页上、浮起的输入框开着时整排让开（`Dock.stays`）。
/// 与屏幕圆角同心（同系统悬浮标签栏），只是玻璃：栏后面不垫渐变或模糊。
/// 接力的"会话"那一头（`relaySpot(dock:)`）只在两格展开时的"进展"那一格（会话在进展里）；收起的"⋯"不接力：光落进"⋯"读不出是去了哪，深色下只剩一团发光的靛青点。
/// 减弱动态效果时不换形，直接到新样子。
struct DockBar: View {
    let motion: DockMotion
    let width: CGFloat
    /// 最上面那一页留着这一排（`Dock.stays`）。
    let stays: Bool
    let openPlaces: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DockForm(places: motion.places, motion: motion, width: width, openPlaces: openPlaces)
            .animation(Motion.travel, value: motion.places)
            .opacity(stays ? 1 : 0)
            .allowsHitTesting(stays)
            .accessibilityHidden(!stays)
            .animation(Motion.travel, value: motion.composing)
            .animation(Motion.travel, value: stays)
            .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// 换形的每一帧都从 `places` 算（`Animatable`）：弹簧逐帧插的是它，不是首尾两个样子之间直线过渡（`DockHandoff`）。
/// 切 tab 时页是一下换走的：离开 Cue 时输入框跟着页没了，没有可交叉的，Cue 钮的玻璃、字与头像一直在，只长回原来的大小。
private struct DockForm: View, Animatable {
    var places: CGFloat
    let motion: DockMotion
    let width: CGFloat
    let openPlaces: (Bool) -> Void

    var animatableData: CGFloat {
        get { places }
        set { places = newValue }
    }

    var body: some View {
        // 左边两样各自的浓淡；浓过一半才点得到、读得到
        let shown = places > 0.5, composing = motion.composing
        let tabs = composing ? 0 : DockHandoff.ramp(places, DockHandoff.tabs)
        let more = composing ? 0 : 1 - DockHandoff.ramp(places, DockHandoff.more)
        let grow = DockHandoff.ramp(places, DockHandoff.grow)
        let crossing = motion.onCue ? places : 1
        let left = Dock.slot + (Dock.capsule(in: width) - Dock.slot) * grow
        let height = Dock.slot + (Dock.height - Dock.slot) * grow
        ZStack(alignment: .bottomLeading) {
            DockTabs(motion: motion, width: width, relays: tabs > 0.5)
                .opacity(tabs)
                .allowsHitTesting(tabs > 0.5)
                .accessibilityHidden(tabs <= 0.5)
            DockMore { openPlaces(true) }
                .opacity(more)
                .allowsHitTesting(more > 0.5)
                .accessibilityHidden(more <= 0.5)
            DockCue(places: crossing) { openPlaces(false) }
                .frame(width: max(0, width - left - Dock.gap), height: height)
                .clipShape(.capsule)
                .glass(in: .capsule, interactive: true)
                .offset(x: left + Dock.gap)
                .opacity(DockHandoff.ramp(crossing, DockHandoff.cueGlass))
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
    }
}

/// Cue 页上收起的"⋯"：一颗与输入框同高的玻璃，点它展开两格。
private struct DockMore: View {
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            IconImage(.more).font(.system(size: 20, weight: .medium))
                .frame(width: Dock.slot, height: Dock.slot)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .glass(in: .circle, interactive: true, ink: .clear)
        .accessibilityLabel("去处")
        .accessibilityHint("展开项目、进展")
    }
}

/// 底部那一排右边的 Cue 钮：占两格宽，右端是它的头像（表情、在动时右下的靛青点，`CueAvatar`；又来一句时外漾一圈 `CueArrival`），
/// 左边两行"推进中 N"、"等你 M"（`DockTally`）；点它去 Cue 页。iPhone 上 Cue 的新消息只提示在这里：
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
                CueAvatar(cue.beat, size: .header)
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
        .accessibilityValue(Dotted(cue.unread > 0 ? String(localized: "\(cue.unread) 条新消息") : nil, DockTally.spoken(cue), drafted ? String(localized: "有草稿") : nil).spoken)
    }

    /// 在 Cue 页上（"⋯"展开着）点它是收起、回到输入框；在别的 tab 上是换到 Cue，推在 Cue 页上的页上是回到 Cue 页（`Workspace.tap`）。
    private func open() {
        guard workspace.top != .cue else {
            collapse()
            return
        }
        workspace.tap(.cue)
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
        .animation(Motion.fade, value: drafted)
    }
}

/// Cue 钮左边的两行：上"推进中 N"（次要墨色），下"等你 M"（`WaitingCount`，赭黄）；为 0 的那行不写，都为 0 写 Cue 此刻那一句
/// （`CueNow.quietLine`：还没启用、哪台没开、在做的那一步、手上没有事……，同页头与小组件）。
/// 两个数就是 Cue 此刻的（`CueNow.advancing`、`CueNow.needsYou`，都出自 `CueStore.cueTally`），不另算。计数与句子共用整组 handOff 交接；那一句长了按尾截断。
private struct DockTally: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static func spoken(_ cue: CueWatch) -> String {
        guard cue.now.advancing > 0 || cue.now.needsYou > 0 else { return cue.now.quietLine }
        return Dotted(cue.now.advancing > 0 ? String(localized: "推进中 \(cue.now.advancing)") : nil, cue.now.needsYou > 0 ? String(localized: "等你 \(cue.now.needsYou)") : nil).spoken
    }

    var body: some View {
        let cue = workspace.cue
        VStack(alignment: .leading, spacing: 2) {
            if cue.now.advancing > 0 {
                Text("推进中 \(cue.now.advancing)").monospacedDigit().foregroundStyle(palette.ink2).rollingCount(cue.now.advancing)
            }
            WaitingCount(count: cue.now.needsYou)
            if cue.now.advancing == 0, cue.now.needsYou == 0 {
                Text(cue.now.quietLine).foregroundStyle(palette.ink3).rollingCount(cue.now.quietLine)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .handOff(id: cue.now.advancing == 0 && cue.now.needsYou == 0
            ? [HandOff.wording(cue.now.quietLine)]
            : [cue.now.advancing > 0 ? "advancing" : nil, cue.now.needsYou > 0 ? "waiting" : nil].compactMap { $0 })
    }
}
#endif

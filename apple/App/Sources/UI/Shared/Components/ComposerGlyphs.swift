import SwiftUI

/// 输入框里的圆钮（看得见的 40，点得到的 44）：＋ 与主按钮（`SendGlyph`）同一个。
struct CircleGlyph<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: ComposerMetrics.glyph, height: ComposerMetrics.glyph)
            .background(fill, in: .circle)
            .frame(width: ComposerMetrics.glyphTarget, height: ComposerMetrics.glyphTarget)
            .contentShape(.circle)
    }
}

/// 输入框右下角的主按钮，全 App 的输入框只此一颗。发送是纸飞机（与"交给"同一架，`Icon.send`），记下是勾，停止是圆角方墨，通话是声纹，挂断是叉：
/// 同一个字形换符号，几样之间来回都原地换，中途反向从此刻的样子接着走。
/// 发送中（话在路上，与会话状态标同一个）：发出那一刻钮底当帧换掉、飞机往右上飞走淡出，同一刻机头处起飞一点光（`RelayLaunch`，"对 Cue 说"才有）——
/// 钮底不渐变，靛青的光才不会压在靛青的钮上看不见。
/// 按下照 `PressFeedback`（由外面的按钮给）。减弱动态效果：换状态只淡入淡出，不跳、不走，发送中是静止的"话在路上"。
struct SendGlyph: View {
    enum Phase: Equatable {
        case idle, ready, sending, stop, stopping
        /// 记下（随手记、Cue 没启用时）：勾，能按时靛青。
        case save(enabled: Bool)
        case call(enabled: Bool)
        /// 挂断（手机通话中，代替发送那一位）：墨色实心，同停止。
        case hangUp
    }

    let phase: Phase
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 变成可发送的次数：每变一次跳一下（只在进入时，离开不跳）。
    @State private var hops = 0

    init(_ phase: Phase) { self.phase = phase }

    var body: some View {
        CircleGlyph(fill: disc) {
            ZStack {
                switch phase {
                case .sending: onTheWay.transition(.opacity)
                case .stopping: Spinner(.small).transition(.opacity)
                case .idle, .ready, .call, .hangUp:
                    // 发出：飞机往右上飞走淡出（减弱动态效果时只淡出）；离开时用的是离开前那一刻的这一句，所以只有发送飞走
                    glyph.transition(.asymmetric(insertion: .opacity,
                                                 removal: phase == .ready && !reduceMotion ? .offset(Self.flight).combined(with: .opacity) : .opacity))
                default: glyph.transition(.opacity)
                }
            }
            .animation(Motion.fade, value: phase)
        }
        // 钮底：发出那一刻当帧换掉，其余换状态时渐变
        .animation(phase == .sending ? nil : Motion.fade, value: disc)
        .onChange(of: phase) { _, new in if new == .ready, !reduceMotion { hops += 1 } }
    }

    private var disc: Color {
        switch phase {
        case .idle, .sending, .stopping, .save(enabled: false), .call: palette.fill
        case .ready, .save(enabled: true): palette.signatureFill
        case .stop, .hangUp: palette.ink
        }
    }

    /// 发送、记下、停止的字形：颜色跟着钮插值；飞机与勾、方块之间整个淡换（飞机自己一个身份，发出时才飞得走）。
    private var glyph: some View {
        let (icon, ink, size): (Icon, Color, CGFloat) = switch phase {
        case .stop: (.stop, palette.paper, 14)
        case .save(let enabled): (.save, enabled ? palette.onFill : palette.ink3, 17)
        case .call(let enabled): (.call, enabled ? palette.ink : palette.ink3, 18)
        case .hangUp: (.close, palette.paper, 14)
        case .ready: (.send, palette.onFill, Self.sendSide)
        default: (.send, palette.ink3, Self.sendSide)
        }
        return Image(icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ink)
            // 减弱动态效果时系统把符号的替换换成淡入淡出
            .contentTransition(.symbolEffect(.replace.offUp))
            // 刚能发的那一下：上翼、下翼依次往上一跳
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: hops)
    }

    /// 飞机与发送中那架一样大：发出时飞机飞走，接着同一架一趟趟飞过。
    private static let sendSide: CGFloat = 22
    /// 发出时飞机飞多远（往右上，顺着机头）：飞出钮的圆底再淡完。
    private static let flight = CGSize(width: 14, height: -14)

    /// 发送中 = 话在路上，与会话状态标同一个（`OnTheWay`）。
    private var onTheWay: some View { OnTheWay(size: Self.sendSide, color: palette.signature) }
}

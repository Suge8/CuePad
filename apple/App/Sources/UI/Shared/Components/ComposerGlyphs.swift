import SwiftUI

/// 输入框里的圆钮（看得见的 36，点得到的 44）：＋ 与主按钮（`SendGlyph`）同一个。
struct CircleGlyph<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: 36, height: 36)
            .background(fill, in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}

/// 输入框右下角的主按钮，全 App 的输入框只此一颗（"对 Cue 说"、会话回复框、随手记、新会话、发给 Agent）。墨块的样子：钮是一块实心圆，
/// 字形是刻出来的反色——发送是燕尾箭镞加一截箭杆，记下是勾，停止是一块圆角方墨。
/// - 不可发送：淡底、淡墨；可发送（主动作）：靛青实心，变成可发送的那一下箭杆、箭镞依次往上一跳。
/// - 发送中（话在路上，与会话状态标同一个）：淡底上三块靛青的 V 从下往上依次亮（`LoopLayer.climb`）；发出那一刻钮底当帧换掉、
///   整支箭往上走掉淡出，同一刻箭镞处起飞一点光（`RelayLaunch`，"对 Cue 说"才有）——钮底不渐变，靛青的光才不会压在靛青的钮上看不见。
/// - 停止（Agent 跑一轮时代替发送）：墨色实心方块；停止请求发出、这一轮还没歇下时换成转圈，不能再点。
/// 按下照 `PressFeedback`（由外面的按钮给）。减弱动态效果：换状态只淡入淡出，不跳、不走，发送中是静止的"话在路上"。
struct SendGlyph: View {
    enum Phase: Equatable {
        case idle, ready, sending, stop, stopping
        /// 记下（随手记、Cue 没启用时）：勾，能按时靛青。
        case save(enabled: Bool)
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
                default:
                    glyph.transition(.asymmetric(insertion: .opacity, removal: reduceMotion ? .opacity : .offset(y: -16).combined(with: .opacity)))
                }
            }
            .animation(Motion.quick, value: phase)
        }
        // 钮底：发出那一刻当帧换掉，其余换状态时渐变
        .animation(phase == .sending ? nil : Motion.quick, value: disc)
        .onChange(of: phase) { _, new in if new == .ready, !reduceMotion { hops += 1 } }
    }

    private var disc: Color {
        switch phase {
        case .idle, .sending, .stopping, .save(enabled: false): palette.fill
        case .ready, .save(enabled: true): palette.signatureFill
        case .stop: palette.ink
        }
    }

    /// 发送、记下、停止共用一个 Image：颜色跟着钮插值，符号原地替换。
    private var glyph: some View {
        let (icon, ink, size): (Icon, Color, CGFloat) = switch phase {
        case .stop: (.stop, palette.paper, 14)
        case .save(let enabled): (.save, enabled ? palette.onFill : palette.ink3, 17)
        case .ready: (.send, palette.onFill, Self.sendSide)
        default: (.send, palette.ink3, Self.sendSide)
        }
        return Image(icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(ink)
            // 减弱动态效果时系统把符号的替换换成淡入淡出
            .contentTransition(.symbolEffect(.replace.offUp))
            // 刚能发的那一下：箭杆、箭镞依次往上一跳
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: hops)
    }

    /// 发送的箭与发送中的三块 V 一样大：发出时箭原地换成往上爬的 V。
    private static let sendSide: CGFloat = 20

    /// 发送中 = 话在路上，与会话状态标同一个：循环交给 `LoopLayer.climb`；减弱动态效果时是状态标同一个静止符号。
    @ViewBuilder private var onTheWay: some View {
        if reduceMotion {
            Image(.onTheWay).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.signature)
        } else {
            LoopLayer(kind: .climb, color: palette.signature).frame(width: Self.sendSide, height: Self.sendSide)
        }
    }
}

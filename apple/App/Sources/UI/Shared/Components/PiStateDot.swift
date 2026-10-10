import CueStore
import SwiftUI

extension PiShown {
    /// 状态标的颜色只回答"要不要你管"：要你确认的赭黄、出错与没能送达胭脂；在动的（工作中、话在路上）是墨色、靠动效表达，
    /// 不占签名色；有新回复墨色；需要 /reload 次要墨色；其余是灰。
    func tint(_ palette: Palette) -> Color {
        switch status {
        case .asking: palette.attention
        case .failed, .delivery(.failed): palette.failure
        case .working, .delivery, .unread: palette.ink
        case .restart: palette.ink2
        case .idle, .fresh, .unknown: palette.ink3
        case .ended: palette.ink3.opacity(0.6)
        }
    }

    /// 状态词的颜色：只有要你动手的那几个字带色，有新回复是墨色（由调用方加粗），已结束是灰，其余次要墨色。整句不上色。
    func labelTint(_ palette: Palette) -> Color {
        needsYou ? tint(palette) : isUnread ? palette.ink : status == .ended ? palette.ink3 : palette.ink2
    }

    /// 状态标的形状，与颜色一起表达状态（色弱也分得出）。工作中与有新回复是自绘的（`PiStateDot`），这里是它们静止时的样子。
    var symbol: String {
        switch status {
        case .asking: "questionmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .delivery(.failed): "arrow.uturn.backward.circle.fill"
        case .restart: "arrow.clockwise.circle.fill"
        // 唤醒：电源键（把歇下的会话打开），不用日出——圈里一道横线加向上箭头读成天气图标
        case .delivery(.waking): "power.circle"
        case .delivery: "arrow.up.circle"
        case .working: "smallcircle.filled.circle"
        case .unread: "circle.fill"
        // 轮到你说话：空的对话气泡。不用对勾——对勾只表示完成与记下，"该你了"读成"做完了"正好相反
        case .idle: "bubble.left"
        case .fresh: "circle.dashed"
        // 不用空心圈：待办任务的圆圈就是它，任务行旁挨着会话状态时分不清
        case .ended: "circle.slash"
        case .unknown: "questionmark.circle"
        }
    }
}

/// 会话状态标（全 App 只此一份：Agent 页、书架、侧栏、Mac 侧栏与菜单栏、会话页顶栏、任务上的会话状态）：颜色 + 形状表达状态——
/// 等你确认赭黄问号、出错胭脂叹号、没能送达胭脂折回箭头、工作中墨色转圈、话在路上墨色向上箭头（唤醒是电源键）在呼吸、
/// 有新回复墨色实心点、该你了灰色空气泡、新会话灰虚线圈、已结束更淡的带斜线圈（不与待办任务的空心圈相混）。`size` 是点的直径，符号按它放大到同样的视觉分量。
/// 转圈与呼吸是常驻的循环动效，交给 Core Animation（`LoopLayer`），标不在屏幕上时不画；换状态时符号淡入替换，
/// 一轮做完（工作中 → 停下）时放一圈涟漪、点弹一下，只这一次。减弱动态效果时转圈换成静止的圈点，没有呼吸与涟漪。
/// 旁边有状态文字时读屏跳过它；`announces` 用在不写状态词的地方（整页的会话行），标自己带读屏标签。
struct PiStateDot: View {
    let shown: PiShown
    var size: CGFloat = 8
    var announces = false
    /// 要你动手的状态（等你确认、出错、没能送达）在标后垫一圈同色淡晕：整页列表里一眼先看到它们。静止，不占动效。
    var halo = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 跟着旁边的字随辅助字号放大
    @ScaledMetric private var scale: CGFloat = 1
    /// 每做完一轮加一：放一次涟漪。
    @State private var finished = 0

    private var box: CGFloat { size * 1.8 * scale }
    /// 字的中线在基线以上多高，按标的外框算（外框约等于旁边的字号）。
    private static let midline = 0.36

    var body: some View {
        let tint = shown.tint(palette)
        let mark = glyph(tint)
            .frame(width: box, height: box)
            .keyframeAnimator(initialValue: Ripple(), trigger: finished) { content, ripple in
                content
                    .scaleEffect(ripple.pop)
                    .background { Circle().stroke(tint, lineWidth: 1.5).scaleEffect(ripple.ring).opacity(ripple.ringOpacity) }
            } keyframes: { _ in
                KeyframeTrack(\.pop) {
                    SpringKeyframe(1.3, duration: 0.14, spring: .snappy)
                    SpringKeyframe(1, duration: 0.4, spring: .bouncy)
                }
                KeyframeTrack(\.ring) { CubicKeyframe(2.4, duration: 0.6) }
                KeyframeTrack(\.ringOpacity) {
                    LinearKeyframe(0.8, duration: 0.05)
                    CubicKeyframe(0, duration: 0.55)
                }
            }
            .background {
                if halo, shown.needsYou { Circle().fill(tint.opacity(palette.dark ? 0.2 : 0.13)).frame(width: box * 1.55, height: box * 1.55) }
            }
            .animation(Motion.quick, value: shown)
            // 旁边是字时按第一行对齐（`.firstTextBaseline`）：每种标都把自己的中心放在那一行字的中线上。不能用各自的基线——
            // 符号有基线、转圈与实心点没有（落到底边），同一列里就高高低低；标的大小跟着旁边的字走，中线离基线约是字高的四成
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + box * Self.midline }
            .onChange(of: shown.status) { old, new in
                if !reduceMotion, case .working = old, [.unread, .idle].contains(new) { finished += 1 }
            }
        if announces {
            // 只给读屏：每行一个悬停提示会让整页每行都挂一块跟踪区，滚动时跟着重算
            mark.accessibilityLabel(shown.presence)
        } else {
            mark.accessibilityHidden(true)
        }
    }

    @ViewBuilder private func glyph(_ tint: Color) -> some View {
        switch shown.status {
        case .working where !reduceMotion:
            // 圈点的圈换成转着的一段弧：静止的列表里只有渲染服务在动
            ZStack {
                LoopLayer(kind: .orbit, color: tint).padding(box * 0.1)
                Circle().fill(tint).frame(width: box * 0.36, height: box * 0.36)
            }
        case .unread:
            Circle().fill(tint).frame(width: size * scale, height: size * scale)
        default:
            Image(systemName: shown.symbol).font(.system(size: box, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .background { if shown.isLive, !reduceMotion { LoopLayer(kind: .breath, color: tint.opacity(0.28)) } }
        }
    }

    private struct Ripple {
        var pop: CGFloat = 1
        var ring: CGFloat = 1
        var ringOpacity: Double = 0
    }
}

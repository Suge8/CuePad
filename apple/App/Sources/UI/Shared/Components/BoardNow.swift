import CueStore
import SwiftUI

/// 推进中卡的第二行：状态标（全 App 那一颗，`StateDot`，与侧栏的会话同一个）、状态词、近况那一句；在跑的那一句上有一道光扫过。
/// 否决过：卡下沿一条线（几颗点加一截波浪、按回合分节的条）——能画的只有"你什么时候说过话"，读不出东西。
/// 一列里排在第 `maxMoving` 张以后的不放光（`moves` 由列按先后给）："同屏最多几张"要逐张读几何才判得出，按列里的先后数是最轻的等价做法。
struct BoardNow: View {
    let pulse: BoardPulse
    let said: String?
    var moves = true
    @Environment(\.palette) private var palette
    @LoopsPlay private var plays

    static let maxMoving = 8
    private static let mark: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            if let shown = pulse.shown {
                StateDot(shown: shown, size: Self.mark)
                BoardWord(pulse: pulse).layoutPriority(1)
            }
            if let handoff = pulse.handoff {
                HandoffLine(handoff: handoff).foregroundStyle(palette.ink2)
            } else if let said {
                let line = Text(verbatim: said)
                line.foregroundStyle(pulse.tier == .resting ? palette.ink3 : palette.ink2)
                    .overlay { if moves, plays, pulse.tier == .running { LoopLayer(kind: .sheen, color: palette.signature).mask { line }.allowsHitTesting(false) } }
            }
        }
        .font(TaskMetrics.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerHidden(true)
    }
}

/// 要你管的写原因（上下文快满时是那个百分比），别的写它此刻在干什么；颜色只出自 `BoardPulse.tint`。
struct BoardWord: View {
    let pulse: BoardPulse
    @Environment(\.palette) private var palette

    var body: some View {
        if case .context(let meter) = pulse.word {
            ContextFact(meter: meter)
        } else if let shown = pulse.shown {
            Text(shown.label).fontWeight(.semibold).foregroundStyle(pulse.tint(palette))
        }
    }
}

/// 卡脚右端：此刻这个状态多久了；上下文只在吃紧时画（宽裕的每张卡都画一圈，一列全是圈）。
/// 状态词已经写了百分比、或卡脚上已经是"现在压缩"时不再画：同一件事不说两遍。
struct BoardVitals: View {
    let pulse: BoardPulse
    @Environment(\.palette) private var palette

    private static let ring: CGFloat = 10
    private static let stroke: CGFloat = 2

    private var meter: ContextMeter? {
        if case .context = pulse.word { return nil }
        guard let session = pulse.session, SessionRescue.of(session) != .compact else { return nil }
        return session.context.flatMap(ContextMeter.init).flatMap { $0.level == .roomy ? nil : $0 }
    }

    var body: some View {
        HStack(spacing: Spacing.item) {
            if let meter {
                let tint = meter.level.ink(palette)
                HStack(spacing: Spacing.tight) {
                    Circle().stroke(palette.track, lineWidth: Self.stroke)
                        .overlay { Circle().trim(from: 0, to: meter.fraction).stroke(tint, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round)).rotationEffect(.degrees(-90)) }
                        .frame(width: Self.ring, height: Self.ring)
                    Text(meter.percent).monospacedDigit().foregroundStyle(tint)
                }
                .help(meter.help.visible)
            }
            if let clock = pulse.shown?.clock { TimeSpent(clock: clock) }
        }
        .fixedSize()
    }
}

/// 同卡脚别的字一个轻重：数字加粗、单位小一号时，一列卡的右下角各有一个抢眼的数。
struct TimeSpent: View {
    let clock: SessionClock
    @Environment(\.palette) private var palette

    var body: some View {
        LiveText(style: clock.live(.span)) { [ink = palette.ink3] text in Text(text).monospacedDigit().foregroundStyle(ink) }
    }
}

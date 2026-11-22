import CueStore
import SwiftUI

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

struct BoardVitals: View {
    let pulse: BoardPulse
    @Environment(\.palette) private var palette

    private static let ring: CGFloat = 10
    private static let stroke: CGFloat = 2

    private var meter: ContextMeter? {
        if case .context = pulse.word { return nil }
        return pulse.session?.context.flatMap(ContextMeter.init).flatMap { $0.level == .roomy ? nil : $0 }
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

struct TimeSpent: View {
    let clock: SessionClock
    @Environment(\.palette) private var palette

    var body: some View {
        LiveText(style: clock.live(.span)) { [ink = palette.ink3] text in Text(text).monospacedDigit().foregroundStyle(ink) }
    }
}

import CueStore
import SwiftUI

struct ContextGauge: View {
    let session: SessionState
    let meter: ContextMeter?
    var cache: ChatMessage.Tools.Cache?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var showsDetail = BubbleSwitch()
    @State private var shown = ContextShown()

    private var facts: ContextShown.Facts { .init(meter: meter, cache: cache, working: session.runtimeState.isWorking) }

    var body: some View {
        Moments(next: { cache?.nextTick(after: $0) }) { now in
            let note = CacheNote(cache, working: facts.working, at: now)
            if meter != nil || note != nil {
                let help = (meter?.help ?? Dotted([])) + Dotted(note?.line)
                Button { showsDetail.toggle() } label: { label(note) }
                    .buttonStyle(PressStyle())
                    .help(help.visible)
                    .bubble(isPresented: $showsDetail.open) { ContextDetail(shown: shown, compact: compact) }
                    .accessibilityLabel("上下文")
                    .accessibilityValue(help.spoken)
            }
        }
        .animation(Motion.fade, value: meter)
        .onChange(of: facts, initial: true) { shown.facts = facts }
    }

    private func label(_ note: CacheNote?) -> some View {
        ViewThatFits(in: .horizontal) {
            row(note, words: true)
            row(note, words: false)
        }
        .chip()
        .animation(Motion.fade, value: note)
    }

    private func row(_ note: CacheNote?, words: Bool) -> some View {
        HStack(spacing: Spacing.item) {
            if let meter {
                HStack(spacing: Spacing.tight) {
                    ContextArc(meter: meter)
                    Text(verbatim: meter.percent).monospacedDigit()
                        .foregroundStyle(meter.level == .roomy ? palette.ink2 : palette.ink)
                        .contentTransition(.numericText(value: meter.fraction))
                }
            }
            if let note { CacheMark(note: note, words: words).transition(.opacity) }
        }
        .fixedSize()
        .readerHidden(true)
    }

    private func compact() {
        showsDetail.open = false
        workspace.compact(session)
    }
}

@Observable private final class ContextShown {
    struct Facts: Equatable {
        var meter: ContextMeter?
        var cache: ChatMessage.Tools.Cache?
        var working = false
    }

    var facts = Facts()
}

private struct ContextDetail: View {
    let shown: ContextShown
    let compact: () -> Void
    @Environment(\.palette) private var palette

    private static let width: CGFloat = 240

    var body: some View {
        let facts = shown.facts
        Moments(next: { facts.cache?.nextTick(after: $0) }) { now in
            let note = CacheNote(facts.cache, working: facts.working, at: now)
            VStack(alignment: .leading, spacing: Spacing.item) {
                HStack(alignment: .firstTextBaseline) {
                    Text("上下文").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
                    Spacer(minLength: Spacing.block)
                    if let meter = facts.meter { Text(meter.percent).font(Typography.secondary.weight(.semibold).monospacedDigit()).foregroundStyle(palette.ink) }
                }
                if let meter = facts.meter {
                    HStack(spacing: Spacing.group) {
                        MarkedBar(fill: meter.fraction, mark: meter.mark, level: meter.level)
                        if meter.suggestsCompact { RescueDisc(icon: .compacting, title: "现在压缩", action: compact) }
                    }
                    Text(meter.compactLine ?? meter.summary.visible).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                }
                if let note {
                    Label { Text(note.line) } icon: { Image(note.icon) }
                        .font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: Self.width, alignment: .leading)
            .padding(Spacing.block)
        }
    }
}

private struct ContextArc: View {
    let meter: ContextMeter
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 17

    private static let sweep = 0.75
    private static let least = 0.05
    private static let notch: CGFloat = 2

    private var line: CGFloat { side * 0.2 }

    private var ink: Color {
        switch meter.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy: palette.ink2
        }
    }

    var body: some View {
        let round = StrokeStyle(lineWidth: line, lineCap: .round)
        ZStack {
            arc(0, 1).stroke(palette.track, style: round)
            if let mark = meter.mark {
                let half = Double(Self.notch / 2 / (.pi * (side - line) * Self.sweep))
                arc(mark - half, mark + half).stroke(.black, lineWidth: line + 1).blendMode(.destinationOut)
            }
            arc(0, max(meter.fraction, Self.least)).stroke(ink, style: round)
        }
        .compositingGroup()
        .offset(y: side * 0.06)
        .frame(width: side, height: side)
    }

    private func arc(_ from: Double, _ to: Double) -> some Shape {
        Circle().inset(by: line / 2).trim(from: from * Self.sweep, to: to * Self.sweep).rotation(.degrees(135))
    }
}

private struct CacheMark: View {
    let note: CacheNote
    let words: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.hair) {
            Image(note.icon)
            if words {
                switch note {
                case .warm(let minutes, _): Text(verbatim: "\(minutes)m").contentTransition(.numericText(countsDown: true))
                case .cold(let tokens, _): Text(verbatim: CueContext.tokens(tokens))
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(palette.ink3)
    }
}

extension CacheNote {
    var icon: Icon {
        switch self {
        case .warm: .warm
        case .cold: .cold
        }
    }
}

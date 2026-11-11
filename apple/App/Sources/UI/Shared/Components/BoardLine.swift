import CueStore
import SwiftUI

extension EnvironmentValues {
    @Entry var boardSaid: [String: [Date]] = [:]
}

/// 右段固定占 `nowShare`：每张卡的现在在同一位置、同一长度，一列读起来整齐。
/// 一列里排在第 `maxMoving` 条以后的静止（`moves` 由列按先后给）："同屏最多几条"要逐行读几何才判得出，每行一个几何读数的开销比省下的动画还大，按列里的先后数是最轻的等价做法：列从上往下读，排在前面的就是一屏里先看到的。
struct BoardLine: View {
    let pulse: BoardPulse
    var moves = true
    /// 会话条只画「现在」，与卡片共用绘线、状态色与循环预算，不复制一份波形实现。
    var detail: Detail = .history
    enum Detail { case history, now }
    @Environment(\.boardSaid) private var said
    @Environment(\.palette) private var palette
    @LoopsPlay private var plays

    static let maxMoving = 8
    static let maxTracks = 3
    nonisolated static let maxSaid = 6
    private static let nowShare: CGFloat = 0.42
    nonisolated fileprivate static let stroke: CGFloat = 1.5
    private static let endDot: CGFloat = 6

    var body: some View {
        Group {
            if detail == .now {
                HStack(spacing: 0) {
                    if pulse.tier == .running { Circle().fill(pulse.tint(palette)).frame(width: Self.endDot, height: Self.endDot) }
                    now(joint: false)
                }
            } else {
                history
            }
        }
        .frame(height: WaveStrip.height)
        .readerHidden(true)
    }

    private var history: some View {
        BoardLineRow {
            Group {
                if let handoff = pulse.handoff {
                    HandoffLine(handoff: handoff).font(TaskMetrics.caption).foregroundStyle(palette.ink2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let marks = PastDots.marks(said: pulse.session.flatMap { said[$0.sessionID] } ?? [], origin: pulse.session?.createdAt)
                    LineSplit(share: Self.nowShare) {
                        past(marks)
                        now(joint: !marks.isEmpty)
                    }
                }
            }
            // 不画时排成 0 宽裁掉：钉在左端的那颗点不漏出来
            .fact()
            .layoutValue(key: BoardLineRow.Part.self, value: .line)
            Group {
                if let clock = pulse.shown?.clock { TimeSpent(clock: clock).fact().layoutValue(key: BoardLineRow.Part.self, value: .time) }
                switch pulse.word {
                case .state(let shown): Text(shown.label).font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(pulse.tint(palette)).fact()
                case .context(let meter): ContextFact(meter: meter).font(TaskMetrics.caption).fact()
                case nil: EmptyView()
                }
            }
            .lineLimit(1)
            .allowsTightening(true)
        }
    }

    private func past(_ marks: [CGFloat]) -> some View {
        PastLine(marks: marks)
            .fill(LinearGradient(stops: [.init(color: palette.track.opacity(0), location: 0), .init(color: palette.track, location: 0.3)], startPoint: .leading, endPoint: .trailing))
            .overlay { PastDots(marks: marks, pick: .earlier).fill(palette.ink3) }
            .overlay { PastDots(marks: marks, pick: .last).fill(pulse.lastSaidTint(palette)) }
    }

    @ViewBuilder private func now(joint: Bool) -> some View {
        switch pulse.trace {
        case .running(let gait, let subagents):
            let strip = WaveStrip(gait: gait, tracks: min(subagents, Self.maxTracks))
            Group {
                if moves && plays {
                    LoopLayer(kind: .wave(strip), color: pulse.tint(palette))
                } else {
                    strip.still.stroke(pulse.tint(palette), style: StrokeStyle(lineWidth: strip.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: strip.tracks > 0 ? .black : .clear, location: 0), .init(color: .black, location: 0.25),
                                       .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            }
        case .stopped(let broken):
            tail(dashed: broken, joint: joint).overlay(alignment: .trailing) { Circle().fill(pulse.tint(palette)).frame(width: Self.endDot, height: Self.endDot) }
        case .resting:
            tail(dashed: false, joint: joint)
        }
    }

    private func tail(dashed: Bool, joint: Bool) -> some View {
        Tail(joint: joint).stroke(palette.track, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round, dash: dashed ? [4, 4] : []))
    }

    private struct TimeSpent: View {
        let clock: SessionClock
        @Environment(\.palette) private var palette

        var body: some View {
            LiveText(style: clock.live(.span)) { text in Self.styled(text, palette) }
        }

        private static func styled(_ text: String, _ palette: Palette) -> Text {
            let count = text.prefix { $0.isNumber }.count
            var digits = AttributedString(text.prefix(count))
            digits.font = Typography.meta.weight(.semibold).monospacedDigit()
            digits.foregroundColor = palette.ink2
            var unit = AttributedString(text.dropFirst(count))
            unit.font = Typography.caption2
            unit.foregroundColor = palette.ink3
            return Text(digits + unit)
        }
    }
}

/// 整行绝不比卡给的宽；读数总靠右，同一列各卡的读数一条竖线对齐。
/// 1280 宽的推进中列里线这一行约 97 宽："达到用量限制""上下文 94%"丢了时长、线也不画，只留词；英文的"Usage limit reached"截断。
/// 否决过：线压到十几点也留着——只剩一颗点挤在词前面，读不出是线，像个标点。
/// 每次排版各量一次理想宽，不按 `ViewThatFits` 把几种排法都建出来；丢掉的排成 0 宽裁掉（`fact()`），读屏仍由卡的标签说状态。
/// 被否决的：读数 `fixedSize`、线占剩下的——卡一窄读数就越过卡的右沿（1280 宽的推进中列，"1 小时 达到用量限制"）。
struct BoardLineRow: Layout {
    enum Part: LayoutValueKey {
        case line, time, word
        static let defaultValue = Part.word
    }

    private static let gap: CGFloat = 8
    private static let pair: CGFloat = 4
    private static let tight: (gap: CGFloat, pair: CGFloat) = (4, 2)

    private struct Plan {
        let line: CGFloat?
        let pair: CGFloat
        let spare: Bool
    }

    private static let plans = [
        Plan(line: gap, pair: pair, spare: true), Plan(line: tight.gap, pair: tight.pair, spare: true), Plan(line: tight.gap, pair: tight.pair, spare: false),
        Plan(line: nil, pair: tight.pair, spare: true), Plan(line: nil, pair: tight.pair, spare: false),
    ]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? WaveStrip.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let line = subviews.first { $0[Part.self] == .line }
        let time = subviews.first { $0[Part.self] == .time }
        let word = subviews.first { $0[Part.self] == .word }
        let (keep, spare) = word.map { ($0, time) } ?? (time, nil)
        let keepWidth = keep?.sizeThatFits(.unspecified).width ?? 0
        let spareWidth = spare?.sizeThatFits(.unspecified).width ?? 0
        func room(_ plan: Plan) -> CGFloat { bounds.width - (plan.line.map { BoardCardMetrics.lineMin + (keep == nil ? 0 : $0) } ?? 0) }
        let plan = Self.plans.first { plan in
            keepWidth + (plan.spare && spare != nil ? spareWidth + plan.pair : 0) <= room(plan) + 0.5
        } ?? Self.plans[Self.plans.count - 1]
        let shownKeep = min(keepWidth, max(0, room(plan)))
        let shownSpare = plan.spare ? spareWidth : 0
        var x = bounds.maxX
        let height = bounds.height
        if let keep {
            x -= shownKeep
            keep.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: shownKeep, height: height))
        }
        if let spare {
            if shownSpare > 0 { x -= plan.pair + shownSpare }
            spare.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: shownSpare, height: height))
        }
        if keep != nil, let gap = plan.line { x -= gap }
        let lineWidth = plan.line == nil ? 0 : max(0, x - bounds.minX)
        line?.place(at: bounds.origin, proposal: ProposedViewSize(width: lineWidth, height: height))
    }
}

private struct LineSplit: Layout {
    let share: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? WaveStrip.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let now = (bounds.width * share).rounded()
        let past = bounds.width - now
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: past, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + past, y: bounds.minY), proposal: ProposedViewSize(width: now, height: bounds.height))
    }
}

nonisolated private struct PastDots: Shape {
    enum Pick { case earlier, last }
    let marks: [CGFloat]
    let pick: Pick

    static let spacing: CGFloat = 9
    static let hole: CGFloat = 4.5

    func path(in rect: CGRect) -> Path {
        let xs = Self.xs(marks, width: rect.width)
        let radius: CGFloat = pick == .last ? 3 : 2.5
        return Path { path in
            for x in pick == .last ? xs.suffix(1) : xs.dropLast() {
                path.addEllipse(in: CGRect(x: x - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    static func xs(_ marks: [CGFloat], width: CGFloat) -> [CGFloat] {
        var xs = marks.map { $0 * width }
        for index in xs.indices.reversed().dropFirst() { xs[index] = min(xs[index], xs[index + 1] - spacing) }
        return xs.indices.compactMap { index in index == xs.count - 1 ? max(xs[index], spacing) : xs[index] >= spacing ? xs[index] : nil }
    }

    /// 会话记录晚于第一句才建的，第一句前也留一分钟那么宽。
    static func marks(said: [Date], origin: Date?) -> [CGFloat] {
        guard let first = said.first else { return [] }
        let times = [min(origin ?? first, first)] + said
        let gaps = zip(times, times.dropFirst()).map { max(sqrt(max($1.timeIntervalSince($0), 0) / 60), 1) }
        let total = gaps.reduce(0, +)
        var at: CGFloat = 0
        return gaps.map { gap in
            at += gap / total
            return at
        }
    }
}

nonisolated private struct PastLine: Shape {
    let marks: [CGFloat]

    func path(in rect: CGRect) -> Path {
        let half = BoardLine.stroke / 2
        var x: CGFloat = 0
        return Path { path in
            for dot in PastDots.xs(marks, width: rect.width) {
                if dot - PastDots.hole > x { path.addRect(CGRect(x: x, y: rect.midY - half, width: dot - PastDots.hole - x, height: half * 2)) }
                x = dot + PastDots.hole
            }
            if rect.maxX > x { path.addRect(CGRect(x: x, y: rect.midY - half, width: rect.maxX - x, height: half * 2)) }
        }
    }
}

nonisolated private struct Tail: Shape {
    let joint: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: joint ? PastDots.hole : 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
        }
    }
}

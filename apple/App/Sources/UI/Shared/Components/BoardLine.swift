import CueStore
import SwiftUI

extension EnvironmentValues {
    @Entry var boardSaid: [String: [Date]] = [:]
}

/// 回合条：你每说一次话起一节（`recentSaid`），一节的长短是那一轮花的时间（开方后按比例，长的不把短的挤没），越早的越淡；
/// 最右一节是此刻这一轮——在跑的有一道光从头走到尾，停下要你管的末端一截状态色，歇着的与过去的同色。
/// 否决过：发丝线上几颗点加一截波浪——点读不出是回合，波浪只是装饰，细到在卡上像没画完。
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
    /// 停下的那一节末端染状态色的一截。
    private static let endCap: CGFloat = 10

    var body: some View {
        Group {
            if detail == .now {
                now
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
                    let marks = PastBars.marks(said: pulse.session.flatMap { said[$0.sessionID] } ?? [], origin: pulse.session?.createdAt)
                    LineSplit(share: Self.nowShare) {
                        PastBars(marks: marks)
                            .fill(LinearGradient(stops: [.init(color: palette.track.opacity(0), location: 0), .init(color: palette.track, location: 0.3)], startPoint: .leading, endPoint: .trailing))
                        now
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

    @ViewBuilder private var now: some View {
        switch pulse.trace {
        case .running(let gait, let subagents):
            let strip = WaveStrip(gait: gait, tracks: min(subagents, Self.maxTracks))
            if moves && plays {
                LoopLayer(kind: .wave(strip), color: pulse.tint(palette))
            } else {
                strip.still.fill(palette.track).overlay { strip.head.fill(pulse.tint(palette)) }
            }
        case .stopped(let broken):
            NowBar(dashed: broken).fill(palette.track)
                .overlay(alignment: .trailing) { Capsule().fill(pulse.tint(palette)).frame(width: Self.endCap, height: WaveStrip.bar) }
        case .resting:
            NowBar(dashed: false).fill(palette.track)
        }
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

    /// 没给宽时报的是非要不可的那一样（状态词，没有就是时长）的宽：卡脚按它给项目名让地方（`BoardFoot`）。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let needed = { (subviews.first { $0[Part.self] == .word } ?? subviews.first { $0[Part.self] == .time })?.sizeThatFits(.unspecified).width ?? 0 }
        return CGSize(width: proposal.width ?? needed(), height: proposal.height ?? WaveStrip.height)
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

nonisolated private struct PastBars: Shape {
    let marks: [CGFloat]

    /// 一节最短这么长（含它后面的缝）：再短读不出是一节。
    static let spacing: CGFloat = 9
    static let gap: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let ends = marks.isEmpty ? [rect.width] : Self.ends(marks, width: rect.width)
        var x: CGFloat = 0
        return Path { path in
            for end in ends {
                let bar = CGRect(x: x, y: rect.midY - WaveStrip.bar / 2, width: end - Self.gap - x, height: WaveStrip.bar)
                if bar.width >= WaveStrip.bar { path.addRoundedRect(in: bar, cornerSize: CGSize(width: WaveStrip.bar / 2, height: WaveStrip.bar / 2)) }
                x = end
            }
        }
    }

    /// 各节的右端：从右往左排，太挤的往左让，让到左沿外的（最早的几节）不画。
    static func ends(_ marks: [CGFloat], width: CGFloat) -> [CGFloat] {
        var xs = marks.map { $0 * width }
        for index in xs.indices.reversed().dropFirst() { xs[index] = min(xs[index], xs[index + 1] - spacing) }
        return xs.filter { $0 >= spacing }
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

/// 此刻这一节不在跑时的样子：一整节；断了的（被打断）切成几小段。
nonisolated private struct NowBar: Shape {
    let dashed: Bool
    private static let dash: (on: CGFloat, off: CGFloat) = (6, 4)

    func path(in rect: CGRect) -> Path {
        let radius = CGSize(width: WaveStrip.bar / 2, height: WaveStrip.bar / 2)
        let y = rect.midY - WaveStrip.bar / 2
        return Path { path in
            guard dashed else { return path.addRoundedRect(in: CGRect(x: rect.minX, y: y, width: rect.width, height: WaveStrip.bar), cornerSize: radius) }
            for x in stride(from: rect.minX, to: rect.maxX - Self.dash.on, by: Self.dash.on + Self.dash.off) {
                path.addRoundedRect(in: CGRect(x: x, y: y, width: Self.dash.on, height: WaveStrip.bar), cornerSize: radius)
            }
        }
    }
}

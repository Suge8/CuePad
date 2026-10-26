import CueStore
import SwiftUI

extension EnvironmentValues {
    /// 推进中这一列各会话你这边最近说的几句的时刻（`CueStore.recentSaid`）：列读一次交给卡上的线（`BoardLine`），卡不各自读库。
    @Entry var boardSaid: [String: [Date]] = [:]
}

/// 看板推进中卡下沿那条线：整行一条线，状态与颜色只按 `BoardPulse`。
/// - 左段是过去：一条从左端淡入的淡线，你这边最近说的每句一颗点（你、Cue 不分，列读好交给它，`boardSaid`），点在线上挖空；
///   相邻两颗按两句隔了多久开方排开、至少隔 `PastDots.spacing`，第一颗前那段从会话开始算，最后一句落在两段交界；
/// - 右段固定占 `nowShare` 是现在（`BoardPulse.Trace`）：在跑是从最后一颗（靛青）点长出的波浪或子代理直轨（`WaveStrip`）；
///   停住是淡线接到右端、末端一颗与状态词同色的点，被打断是断线；歇着是淡线、不带点。每张卡的现在在同一位置、同一长度，一列读起来整齐；
/// - 右端只写一个时长：会话在此刻这个状态里待了多久（同会话行那一格，`PiClock.Style.span`；数字加粗、单位小一号淡色），要你管的状态词紧跟。
/// 动只经 `LoopLayer`，只有看得见的在动：卡在懒加载栈里，出屏就不存在；不放循环动效时（`LoopsPlay`）静止；
/// 一列里排在第 `maxMoving` 条以后的静止（`moves` 由列按先后给）——"同屏最多几条"要逐行读几何才判得出，每行一个几何读数的开销比省下的动画还大，
/// 按列里的先后数是最轻的等价做法：列从上往下读，排在前面的就是一屏里先看到的。读屏不念：卡的读屏标签已说了状态。
struct BoardLine: View {
    let pulse: BoardPulse
    /// 列里允许它动（排在前 `maxMoving` 条在跑的里）。
    var moves = true
    @Environment(\.boardSaid) private var said
    @Environment(\.palette) private var palette
    @LoopsPlay private var plays

    static let maxMoving = 8
    static let maxTracks = 3
    /// 过去那段至多几颗点。
    static let maxSaid = 6
    private static let nowShare: CGFloat = 0.42
    fileprivate static let stroke: CGFloat = 1.5
    private static let endDot: CGFloat = 6

    var body: some View {
        let marks = PastDots.marks(said: pulse.session.flatMap { said[$0.sessionID] } ?? [], origin: pulse.session?.createdAt)
        HStack(spacing: 8) {
            LineSplit(share: Self.nowShare) {
                past(marks)
                now(joint: !marks.isEmpty)
            }
            reading
        }
        .frame(height: WaveStrip.height)
        .accessibilityHidden(true)
    }

    private func past(_ marks: [CGFloat]) -> some View {
        ZStack {
            PastLine(marks: marks)
                .fill(LinearGradient(stops: [.init(color: palette.track.opacity(0), location: 0), .init(color: palette.track, location: 0.3)], startPoint: .leading, endPoint: .trailing))
            PastDots(marks: marks, pick: .earlier).fill(palette.ink3)
            PastDots(marks: marks, pick: .last).fill(pulse.tier == .running ? palette.signature : palette.ink3)
        }
    }

    /// `joint`：两段交界处有最后一颗点，停住与歇着的线从它挖的空后面接上。
    @ViewBuilder private func now(joint: Bool) -> some View {
        switch pulse.trace {
        case .running(let gait, let subagents):
            let strip = WaveStrip(gait: gait, tracks: min(subagents, Self.maxTracks))
            Group {
                if moves && plays {
                    LoopLayer(kind: .wave(strip), color: palette.signature)
                } else {
                    strip.still.stroke(palette.signature, style: StrokeStyle(lineWidth: strip.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .clipped()
            // 波浪从最后一颗点里渐显、到右端淡出；子代理轨从那颗点直接分岔出去，不淡入
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

    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let clock = pulse.shown?.clock { TimeSpent(live: clock.live(.span)) }
            switch pulse.word {
            case .state(let shown): Text(shown.label).font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(pulse.tint(palette))
            case .context(let meter): ContextFact(meter: meter).font(TaskMetrics.caption)
            case nil: EmptyView()
            }
        }
        .fixedSize()
    }

    /// 时长：数字加粗、单位小一号淡色（"12 分钟""42 sec"；不到一分钟是"刚刚"，整段淡色），只在字会变的那一刻重画（`Moments`）。
    private struct TimeSpent: View {
        let live: PiClock.Live
        @Environment(\.palette) private var palette

        var body: some View {
            Moments(next: live.discreteInput(after:)) { now in
                let text = live.format(now)
                let digits = text.prefix { $0.isNumber }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    if !digits.isEmpty { Text(digits).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink2) }
                    Text(text.dropFirst(digits.count)).font(Typography.caption2).foregroundStyle(palette.ink3)
                }
                .monospacedDigit()
            }
        }
    }
}

/// 两段按比例分：后一段占 `share`。一次排完，不读几何。
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

/// 过去那段的每颗点：位置（0…1）乘宽，挨得太近的往左推开、至少隔 `spacing`，最后一颗钉在右端。
nonisolated private struct PastDots: Shape {
    enum Pick { case earlier, last }
    let marks: [CGFloat]
    let pick: Pick

    static let spacing: CGFloat = 9
    /// 点在线上挖出的空的半径，比最大的点大一圈。
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
        return xs.map { max($0, spacing) }
    }

    /// 说过的每句在过去那段里的位置（0…1），最后一句落在 1：从会话开始起，相邻两个时刻隔多久开方当间距（至少一分钟那么宽），
    /// 久的拉开、密的不挤成一团；会话记录晚于第一句才建的，第一句前也留一分钟那么宽。
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

/// 过去那段的线：竖直居中、细细一条（填充，淡入用渐变填色），每颗点处断开 `PastDots.hole`，线不穿过点。
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

/// 停住与歇着那一截的线：竖直居中，左端让出交界那颗点挖的空（有的话），右端让出末端那颗点的半边。
nonisolated private struct Tail: Shape {
    let joint: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: joint ? PastDots.hole : 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
        }
    }
}

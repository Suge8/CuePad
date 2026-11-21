import CueStore
import SwiftUI

/// 上下文与提示缓存合成一颗胶囊（同模型那颗的 `chip`）：一道仪表弧、用了几成，后面跟着缓存还热几分钟（冷了换成雪花与这一句要重读多少），
/// 点开是挨着它长出的气泡。弧靠近尽头的那道缝是 Agent 自动压缩的线（`ContextMeter.mark`），接近它时弧加深、到线变胭脂；
/// 气泡里那条（`MarkedBar`）在同一处有一道刻度。
/// 否决过：百分数写在圈里——圈只有工具排那么高，字挤到 8 点；圈上一个小点标建议压缩的地方、弧头一颗亮珠——没人认得出点是什么；
/// 缓存另起一颗——同一件事（这段对话还记得多少、接着说贵不贵）分在两处。颜色只描在弧上，数字留给墨色（胭脂字在深色下到不了 4.5:1）。
/// 都是静止的图形，只在用量、剩的分钟变了时补一段过渡。
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

    /// 工具排给的宽放不下就先收缓存的字、留它的记号（`ConfigRow` 的 `wording`）；整颗是候选，同 `ModelPick`
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

/// 气泡的内容在打开那一刻交给浮层宿主，之后不随胶囊重算（同 `ModelPick` 的 `Live`）：用量、缓存、在不在跑放进这只盒子，气泡读它，
/// 剩的分钟由气泡自己到点重画——开着气泡跨过一分钟、跨过缓存冷掉的那一刻，里面写的跟胶囊上的一致。
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
                    MarkedBar(fill: meter.fraction, mark: meter.mark, level: meter.level)
                    // 几成已在右上角；这一行说离压缩线多远，没有线的才说还剩多少。现在就压缩的那颗跟在这句的行尾：它是这句话的另一个选择，
                    // 右沿同上面的百分数、条的尽头一条线。否决过：另起一行一颗带字的胶囊——悬在左下角，同上面三行哪个都不对齐。
                    HStack(spacing: Spacing.group) {
                        Text(meter.compactLine ?? meter.summary.visible).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                        Spacer(minLength: 0)
                        if meter.suggestsCompact { RescueDisc(icon: .compacting, title: "现在压缩", action: compact) }
                    }
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

/// 仪表弧：开口朝下的四分之三圈（同手表上的圆形仪表），用掉的那段从左下顺时针描过去；轨道在压缩线处切一道缝，缝后是过了线才会走到的那一截。
/// 否决过：闭合的圆环——起点与尽头在 12 点碰在一起，用得少时那一小段像加载的转圈；缝后那一截染深——用得少时与起点那一小段一左一右，像一副耳机。
private struct ContextArc: View {
    let meter: ContextMeter
    @Environment(\.palette) private var palette
    /// 与模型胶囊里的标志（`ModelBadge`）差不多大，随字号放大
    @ScaledMetric(relativeTo: .footnote) private var side: CGFloat = 17

    private static let sweep = 0.75
    /// 用得再少也露出一小截弧：只剩圆头的一个点读不出是"用了一点"
    private static let least = 0.05
    /// 压缩线那道缝的宽（点）：同额度条上刻度两侧的缝
    private static let notch: CGFloat = 2

    /// 线宽随圈定，粗到五分之一：再细在胶囊的底上发虚，读不出用了几成
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
        // 开口在下，弧看着偏上：往下挪一点与旁边的字对齐
        .offset(y: side * 0.06)
        .frame(width: side, height: side)
    }

    private func arc(_ from: Double, _ to: Double) -> some Shape {
        Circle().inset(by: line / 2).trim(from: from * Self.sweep, to: to * Self.sweep).rotation(.degrees(135))
    }
}

/// 缓存那一句在胶囊里的样子：记号（钟、雪花）加几个字，放不下只留记号；整句在悬停与气泡里。
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

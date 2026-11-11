import CueStore
import SwiftUI

/// 历史卡第二行都没有也留着：张张卡一样高，长列表扫下去节奏不断。
/// 名字优先，窄处先截名字，标志与时长一直留着。
/// 窄处时长与上下文读数用等宽数字，状态词长短不同也不挪；辅助字号下两层的行尾（时长、上下文）各换到下一行（`MetaLine`）。
struct SessionRow: View {
    let session: SessionState
    let project: Project?
    let delivery: DeliveryRequest?
    var end: Speech.Trip?
    var rename: DeliveryRequest?
    var task: String?
    /// 你看过以后整行不再是"没能送达"，但只要还有，时长前留一个胭脂的小折回箭头，与会话页顶栏同一个数（`Chat.undeliveredNote`）。
    let undelivered: Int
    var style = Style.compact
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.searchHighlight) private var highlight

    struct Style {
        var name: Font
        var line: Font
        var meta: Font
        var dot: CGFloat
        var spacing: CGFloat
        var card = false

        static let page = Style(name: Typography.bodyStrong, line: Typography.secondary, meta: Typography.meta, dot: 11, spacing: Spacing.tight, card: true)
        static let compact = Style(name: Typography.body, line: Typography.meta, meta: Typography.meta, dot: 6, spacing: 1)
    }

    var body: some View {
        let shown = workspace.shown(session, delivery: delivery)
        let facts = services.settings.facts(session, shown: shown, end: end, rename: rename, at: services.speech)
        Group {
            if style.card {
                card(shown: shown, facts: facts)
            } else {
                compact(shown: shown, facts: facts)
            }
        }
        .relayArrival(session: session.sessionID)
    }

    private var ended: Bool { session.state == .known(.ended) && !session.isWaking(by: delivery, at: services.speech) }

    private func card(shown: SessionShown, facts: RowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            if !ended { StateDot(shown: shown, size: style.dot).relaySpot(session: session.sessionID) }
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                MetaLine(spacing: Spacing.item, gap: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                        if let searchHit {
                            Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2)
                        } else if ended {
                            recap.foregroundStyle(palette.ink3)
                        } else {
                            StateWord(shown: shown).fixedSize()
                            if let note = facts.note {
                                NoteWord(note: note)
                            } else if let handoff = workspace.handoff(of: session, shown: shown) {
                                HandoffLine(handoff: handoff).foregroundStyle(palette.ink2)
                            } else if let progress = SessionProgress.note(of: session, failure: nil) {
                                Text(progress).foregroundStyle(palette.ink2)
                            }
                        }
                    }
                } meta: {
                    if let context = facts.context { ContextFact(meter: context).font(style.meta) }
                }
                .font(style.line)
                .lineLimit(1)
            }
        }
        .contentTransition(.opacity)
        .animation(Motion.fade, value: shown)
        .animation(Motion.fade, value: facts)
        .sessionCard(wash: ended ? nil : shown.wash(palette))
        .accessibilityElement(children: .combine)
    }

    private var recap: Text {
        if let reply = SessionProgress.line(of: session) { return Text(reply) }
        if let folder = session.folder { return Text("\(Image(.folder)) \(folder)").accessibilityLabel("在 \(folder)") }
        return Text(verbatim: " ")
    }

    private func compact(shown: SessionShown, facts: RowFacts) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: style.dot + Spacing.hair) {
            StateDot(shown: shown, size: style.dot).relaySpot(session: session.sessionID)
            VStack(alignment: .leading, spacing: style.spacing) {
                headline(shown: shown)
                MetaLine(alignment: .center, spacing: Spacing.item, gap: 0) {
                    if let searchHit {
                        Text(Highlight.matches(searchHit, highlight)).foregroundStyle(palette.ink2).lineLimit(1)
                    } else {
                        StatusLine(shown: shown, facts: facts, handoff: workspace.handoff(of: session, shown: shown))
                    }
                } meta: {
                    if let context = facts.context { ContextFact(meter: context) }
                }
                .font(style.line)
            }
            .contentTransition(.opacity)
            .animation(Motion.fade, value: shown)
            .animation(Motion.fade, value: facts)
        }
        .accessibilityElement(children: .combine)
    }

    private func headline(shown: SessionShown) -> some View {
        MetaLine(spacing: Spacing.item, gap: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                Text(Highlight.matches(task?.nonEmpty ?? SessionRename.title(of: session, request: rename, at: services.speech), highlight))
                    .font(style.name).fontWeight(shown.isUnread ? .bold : nil)
                    .foregroundStyle(style.card && ended ? palette.ink2 : palette.ink).lineLimit(1)
                if session.agentMark != nil { AgentMark(session: session, font: style.meta, named: false).fixedSize() }
            }
        } meta: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                if shown.undelivered == nil, let unsent = Chat.undeliveredNote(undelivered) {
                    StateGlyph.undelivered.font(style.meta.weight(.semibold)).iconLabel(unsent)
                }
                if style.card, let project { ProjectGlyph(project: project, size: Self.placeIcon).iconLabel("在 \(project.shownName)") }
                SessionElapsed(shown: shown, font: style.meta, style: .span)
            }
        }
    }

    private static let placeIcon: CGFloat = 12

    private var searchHit: String? {
        let terms = highlight.split(whereSeparator: \.isWhitespace)
        let hits = { (text: String?) in text.map { text in terms.contains { text.localizedCaseInsensitiveContains($0) } } ?? false }
        guard !terms.isEmpty, !hits(session.title), !hits(project?.shownName ?? session.folder),
              let prompt = (session.pendingPrompt ?? session.lastPrompt)?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
              let hit = terms.lazy.compactMap({ prompt.range(of: $0, options: .caseInsensitive) }).first else { return nil }
        let start = prompt.index(hit.lowerBound, offsetBy: -Self.leadIn, limitedBy: prompt.startIndex) ?? prompt.startIndex
        return String(localized: "你说：\(start == prompt.startIndex ? "" : "…")\(String(prompt[start...]))")
    }

    private static let leadIn = 6
}

/// 行只随自己的数据重算（调用处挂 .equatable()）：会话列表里一个会话的状态变了，别的行不必再排一遍。
extension SessionRow: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.session == b.session && a.project == b.project && a.delivery == b.delivery && a.end == b.end && a.rename == b.rename && a.task == b.task
            && a.undelivered == b.undelivered && a.style.card == b.style.card && a.style.dot == b.style.dot
    }
}

/// 换状态时淡入淡出。静态内容卡：不加阴影与描边，靠纸比桌面亮一档分层。
struct SessionCard: ViewModifier {
    var wash: Color?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        content
            .padding(.horizontal, Spacing.inset).padding(.vertical, Spacing.group)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(wash ?? palette.paper)
                    .animation(Motion.fade, value: wash)
            }
    }
}

extension View {
    func sessionCard(wash: Color? = nil) -> some View { modifier(SessionCard(wash: wash)) }
}

private struct StateWord: View {
    let shown: SessionShown
    @Environment(\.palette) private var palette

    var body: some View {
        Text(shown.label).fontWeight(shown.isColored ? .semibold : .medium).foregroundStyle(shown.labelTint(palette))
    }
}

private struct NoteWord: View {
    let note: RowFacts.Note
    @Environment(\.palette) private var palette

    var body: some View { Text(note.text).foregroundStyle(note.isFailure ? palette.failure : palette.ink2) }
}

private struct SubagentCount: View {
    let summary: SubagentSummary
    @Environment(\.palette) private var palette

    var body: some View {
        let running = Text("\(summary.running)").foregroundStyle(summary.running > 0 ? palette.signature : palette.ink2).fontWeight(.semibold)
        Text("\(Image(.branch))\u{2009}\(running)/\(summary.total)")
            .monospacedDigit().foregroundStyle(palette.ink2)
            .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure, summary.rejection).spoken)
    }
}

private struct StatusLine: View {
    let shown: SessionShown
    let facts: RowFacts
    let handoff: CueHandoff?
    @Environment(\.palette) private var palette

    var body: some View {
        FactsLayout {
            StateWord(shown: shown).fact()
            if let note = facts.note { NoteWord(note: note).fact() }
            if let handoff { HandoffLine(handoff: handoff).foregroundStyle(palette.ink2).fact() }
            if let subagents = facts.subagents { SubagentCount(summary: subagents).fact() }
        }
        .lineLimit(1)
    }
}

struct ContextFact: View {
    let meter: ContextMeter
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = meter.level == .critical ? palette.failure : palette.ink
        Text("\(Text("上下文").foregroundStyle(palette.ink3)) \(Text(meter.percent).foregroundStyle(tint).fontWeight(.semibold))")
            .monospacedDigit()
            .accessibilityLabel(meter.help.spoken)
    }
}

/// 每次排版各量一次理想宽度，不像 `ViewThatFits` 那样把每种排法都试排一遍。
private struct FactsLayout: Layout {
    var spacing = Spacing.item

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let full = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: min(proposal.width ?? full, full), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, fits = true
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            let room = bounds.maxX - x
            let width = !fits ? 0 : ideal.width <= room + 0.5 ? ideal.width : index == 0 ? max(room, 0) : 0
            if index > 0, width == 0 { fits = false }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: ideal.height))
            if width > 0 { x += width + spacing }
        }
    }
}

extension View {
    func fact() -> some View { frame(minWidth: 0, alignment: .leading).clipped() }
}

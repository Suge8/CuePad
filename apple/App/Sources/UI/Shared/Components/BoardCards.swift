import CueStore
import SwiftUI

extension View {
    func boardCard(_ column: TaskBoard.Column, running: Bool = false) -> some View {
        modifier(BoardCardFrame(column: column, running: running))
    }

    func boardDim(project: UUID?) -> some View {
        #if os(macOS)
        modifier(BoardDim(project: project))
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    @Entry var boardRow = false
}

private struct BoardCardFrame: ViewModifier {
    let column: TaskBoard.Column
    let running: Bool
    @LoopsPlay private var plays
    @Environment(\.boardRow) private var row
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(.horizontal, TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: row ? .infinity : nil, alignment: .leading)
            .background {
                if let arrival {
                    RoundedRectangle(cornerRadius: TaskMetrics.cardRadius)
                        .fill(arrival.from.paper(palette) ?? palette.paper).opacity(arrival.landed ? 0 : 1)
                }
            }
            .paper(cornerRadius: TaskMetrics.cardRadius, wash: column.paper(palette))
            .overlay { if running, plays { LoopLayer(kind: .aura(radius: TaskMetrics.cardRadius), color: palette.signature).allowsHitTesting(false) } }
            .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius))
    }
}

#if os(macOS)
private struct BoardDim: ViewModifier {
    let project: UUID?
    @Environment(Workspace.self) private var workspace

    private static let dimmed = 0.35

    func body(content: Content) -> some View {
        let hovered = workspace.hoveredProject
        content
            .opacity(hovered.map { $0 == project } ?? true ? 1 : Self.dimmed)
            .animation(Motion.fade, value: hovered)
    }
}
#endif

struct BoardPin: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.pin).font(.system(size: TaskMetrics.cardGlyph)).foregroundStyle(palette.ink3).readerHidden(true)
    }
}

struct BoardProjectTag: View {
    let project: Project
    var named = true
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.hair) {
            ProjectGlyph(project: project, size: TaskMetrics.cardGlyph)
            if named { Text(project.shownName).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1).fact() }
        }
        .frame(maxWidth: named ? BoardCardMetrics.tagMax : nil, alignment: .leading)
        .help(project.shownName)
        #if os(macOS)
        .onHover { workspace.hoverProject(project.id, $0) }
        .presetHover(Binding { false } set: { if $0 { workspace.hoverProject(project.id, true) } })
        #endif
    }
}

#if os(macOS)
extension Workspace {
    /// 出去时还是它才清掉：指针从一处直接挪到另一处时，先进后出的顺序不定。
    func hoverProject(_ project: UUID, _ inside: Bool) {
        if inside { hoveredProject = project } else if hoveredProject == project { hoveredProject = nil }
    }
}
#endif

/// 拉丁词按词断——词里的连字符换成不断行的（U+2011），"notes-edit"不拆成"notes- / edit"；
/// 整个标题只是一个拉丁词（没有空格、没有汉字）时只排一行，放不下先收字距、再截断，不按字母折行。中文照常按字折，至多两行（辅助字号三行）；手机的行里一行（辅助字号两行）。
/// 几个拉丁词里有一个比一行还长时系统仍会在词中间折：标题里少见，不为它另排。
/// `lines` 给 1 是这张卡第二行非写旁注不可（等你的那句提问）。
struct BoardCardTitle: View {
    let text: String
    var lines: Int?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.boardRow) private var row

    init(_ text: String, lines: Int? = nil) {
        self.text = text
        self.lines = lines
    }

    var body: some View {
        Text(Self.joined(text)).lineLimit(Self.oneWord(text) ? 1 : row ? BoardCardMetrics.rowLines(typeSize) : lines ?? BoardCardMetrics.lines(typeSize)).allowsTightening(true)
    }

    private static func joined(_ text: String) -> String {
        guard text.contains("-") else { return text }
        let chars = Array(text)
        return String(chars.indices.map { index in
            chars[index] == "-" && index > 0 && index < chars.count - 1 && chars[index - 1].isLetterOrDigit && chars[index + 1].isLetterOrDigit ? "\u{2011}" : chars[index]
        })
    }

    private static func oneWord(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { !$0.isWhitespace && !$0.unicodeScalars.contains { $0.properties.isIdeographic } }
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}

struct BoardSessionCard: View {
    let agent: SessionListItem
    let project: Project?
    var moves = true
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var session: SessionState { agent.state }

    var body: some View {
        let pulse = workspace.pulse(of: agent)
        let resting = pulse.tier == .resting
        let name = agent.name(at: workspace.services.speech)
        BoardLink(to: session) {
            BoardCardLayout(advancing: true, pulse: pulse, moves: moves, project: project, note: SessionProgress.said(of: session), session: session) {
                BoardCardTitle(name).foregroundStyle(resting ? palette.ink2 : palette.ink)
            }
            .boardCard(.advancing, running: moves && pulse.tier == .running)
        }
        .boardRescue(session)
        .help(Dotted(project?.shownName, session.agentMark).visible)
        .contextMenu { SessionActions(session: session) }
        .accessibilityLabel(Dotted(name, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label, pulse.handoff?.waiting).spoken)
        .accessibilityActions { SessionActions(session: session) }
    }
}

struct BoardCardLayout<Title: View, Facts: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    let project: Project?
    var note: String?
    var session: SessionState?
    var compact = false
    let title: Title
    let facts: Facts
    let trailing: Trailing
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    init(advancing: Bool, pulse: BoardPulse = BoardPulse(), moves: Bool = true, project: Project?, note: String? = nil, session: SessionState? = nil, compact: Bool = false,
         @ViewBuilder title: () -> Title,
         @ViewBuilder facts: () -> Facts = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.advancing = advancing
        self.pulse = pulse
        self.moves = moves
        self.project = project
        self.note = note
        self.session = session
        self.compact = compact
        self.title = title()
        self.facts = facts()
        self.trailing = trailing()
    }

    var body: some View {
        if row, compact { strip } else { stacked }
    }

    private var strip: some View {
        HStack(spacing: Spacing.item) {
            if let project { BoardProjectTag(project: project, named: false) }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }.font(TaskMetrics.lineFont).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.glyph) { facts }.fixedSize().font(TaskMetrics.caption).lineLimit(1)
            trailing
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
            // 行里卡脚沉到格底：上半截占满余高（中间垫 Spacer 的话它前后各多一个行距，卡比格高）
            VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                HStack(alignment: compact ? .top : .firstTextBaseline, spacing: Spacing.item) {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }.font(compact ? TaskMetrics.lineFont : Typography.bodyStrong)
                        if compact, let note { noteLine(note) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let session { AgentMark(session: session, font: TaskMetrics.caption, named: false) }
                    trailing
                }
                if advancing, pulse.shown != nil || note != nil { BoardNow(pulse: pulse, said: note, moves: moves) }
            }
            .frame(maxHeight: row ? .infinity : nil, alignment: .top)
            BoardFoot(glyph: BoardCardMetrics.footGlyph) {
                if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
                foot
            }
            .boardFootHeight(advancing ? BoardCardMetrics.vitals : BoardCardMetrics.foot)
        }
        .padding(.vertical, compact ? BoardCardMetrics.compactPad : BoardCardMetrics.pad)
    }

    private var foot: some View {
        HStack(spacing: Spacing.item) {
            Spacer(minLength: 0)
            if advancing { BoardVitals(pulse: pulse) } else { HStack(spacing: Spacing.glyph) { facts }.fixedSize() }
            if advancing, let session, SessionRescue.of(session) != nil { BoardRescue(session: session, reserves: true).hidden().frame(height: 0) }
        }
        .font(TaskMetrics.caption).lineLimit(1)
    }

    private func noteLine(_ note: String) -> some View {
        Text(verbatim: note).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1).readerHidden(true)
    }
}

extension View {
    func boardFootHeight(_ height: CGFloat) -> some View { modifier(BoardFootHeight(height: height)) }
}

private struct BoardFootHeight: ViewModifier {
    let height: CGFloat
    @ScaledMetric(relativeTo: .footnote) private var scale = 1.0

    func body(content: Content) -> some View { content.frame(height: height * scale) }
}

struct BoardFoot: Layout {
    let glyph: CGFloat
    private static let nameMin: CGFloat = 36

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tag = subviews[0], facts = subviews[1]
        let wanted = tag.sizeThatFits(.unspecified).width
        let gap = wanted > 0 ? Spacing.item : 0
        let room = min(wanted, max(0, bounds.width - gap - facts.sizeThatFits(.unspecified).width))
        let width = room < glyph ? 0 : room < wanted && room < glyph + Self.nameMin ? glyph : room
        tag.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        let used = width > 0 ? width + gap : 0
        facts.place(at: CGPoint(x: bounds.minX + used, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: bounds.width - used, height: bounds.height))
    }
}

struct BoardShot: View {
    let shot: CueShown
    let group: String
    var hero = false
    let open: (PreviewOpening) -> Void

    var body: some View {
        DeliverableTile(
            preview: shot.preview, label: shot.look, shape: hero ? .hero : .strip(height: Self.height), captioned: false, zoom: PreviewZoomKey(group: group, preview: shot.id)
        ) { _ in open(Self.opening(shot, group: group)) }
    }

    static func opening(_ shot: CueShown, group: String) -> PreviewOpening {
        PreviewOpening(preview: shot.preview, batch: [shot.preview], group: group, looks: [shot.id: shot.look])
    }

    #if os(macOS)
    private static let height: CGFloat = 28
    #else
    private static let height: CGFloat = 34
    #endif
}

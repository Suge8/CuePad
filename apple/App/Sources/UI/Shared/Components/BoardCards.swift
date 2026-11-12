import CueStore
import SwiftUI

extension View {
    /// 平放的纸不加模糊阴影：侧栏开合时整面墙每帧重画，靠纸与桌面的明度、色相差把纸托出来。
    /// `flat`：清单里的一行（待办、没有成果图的已完成），不垫纸，指针停上去才有淡底。
    /// `running`：卡边有一道光绕着走（推进中在跑的卡，一列至多 `BoardNow.maxMoving` 张）。
    func boardCard(_ column: TaskBoard.Column, flat: Bool = false, running: Bool = false) -> some View {
        modifier(BoardCardFrame(column: column, flat: flat, running: running))
    }

    /// 只这一个小修饰读它：指针换项目时重算的是各卡的透明度，不是整张卡。
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
    let flat: Bool
    let running: Bool
    @LoopsPlay private var plays
    #if os(macOS)
    @Environment(\.buttonHovered) private var hovered
    #endif
    @Environment(\.boardRow) private var row
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(.horizontal, row ? BoardCardMetrics.rowPadding : TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: row ? .infinity : nil, alignment: .leading)
            .background {
                if let arrival {
                    RoundedRectangle(cornerRadius: TaskMetrics.cardRadius)
                        .fill(arrival.from.paper(palette) ?? palette.paper).opacity(arrival.landed ? 0 : 1)
                }
            }
            .modifier(Surface(column: column, flat: flat && !row, lit: lit))
            .overlay { if running, plays, !row { LoopLayer(kind: .aura(radius: TaskMetrics.cardRadius), color: palette.signature).allowsHitTesting(false) } }
            .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius))
    }

    private var lit: Bool {
        #if os(macOS)
        hovered
        #else
        false
        #endif
    }

    private struct Surface: ViewModifier {
        let column: TaskBoard.Column
        let flat: Bool
        let lit: Bool
        @Environment(\.palette) private var palette

        func body(content: Content) -> some View {
            if flat {
                content.background(lit ? palette.fill : .clear, in: RoundedRectangle(cornerRadius: TaskMetrics.cardRadius))
            } else {
                content.paper(cornerRadius: TaskMetrics.cardRadius, wash: column.paper(palette))
            }
        }
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

/// 项目只在看全部项目时画（调用方给 nil）：选了项目范围时范围已经说了。指针停在上面时别的项目的卡淡下去（`boardDim`）。
/// 手机的行里格子窄，只画小图形；列里的卡在卡脚左端连名字一起写。
struct BoardProjectTag: View {
    let project: Project
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.hair) {
            ProjectGlyph(project: project, size: TaskMetrics.cardGlyph)
            // 卡脚只给得出图形那么宽时名字排成 0 宽裁掉（`BoardFoot`），不剩一个"…"
            if !row { Text(project.shownName).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1).fact() }
        }
        .frame(maxWidth: row ? nil : BoardCardMetrics.tagMax, alignment: .leading)
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
/// 整个标题只是一个拉丁词（没有空格、没有汉字）时只排一行，放不下先收字距、再截断，不按字母折行。中文照常按字折，至多两行（辅助字号三行）。
/// 几个拉丁词里有一个比一行还长时系统仍会在词中间折：标题里少见，不为它另排。
/// `lines` 给 1 是这张卡第二行非写旁注不可（等你的那句提问）。
struct BoardCardTitle: View {
    let text: String
    var lines: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String, lines: Int? = nil) {
        self.text = text
        self.lines = lines
    }

    var body: some View {
        Text(Self.joined(text)).lineLimit(Self.oneWord(text) ? 1 : lines ?? BoardCardMetrics.lines(typeSize)).allowsTightening(true)
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

/// 拖到已完成、完成、置顶、改名与任务是同一组操作（`Workspace+Adopt`）：第一次这样用时当场给它建任务绑上。
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
                Group {
                    if let kind = session.agent.known { kind.mark.image } else { Image(.terminal) }
                }
                .font(.system(size: TaskMetrics.cardLead * 0.85)).foregroundStyle(resting ? palette.ink3 : palette.ink2)
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
            } title: {
                BoardCardTitle(name).foregroundStyle(resting ? palette.ink2 : palette.ink)
            }
            .boardCard(.advancing, running: moves && pulse.tier == .running)
        }
        .boardRescue(session)
        .help(Dotted(project?.shownName, session.agentMark).visible)
        .contextMenu { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
        .accessibilityLabel(Dotted(name, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label, pulse.handoff?.waiting).spoken)
        .accessibilityActions { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
    }
}

/// 列里的卡：标题（至多两行，右上角是哪家 Agent 的标志）、推进中多一行此刻在干什么（`BoardNow`）、卡脚。
/// 卡脚左端项目，右端这一列要说的那一样——推进中是上下文与时长（`BoardVitals`），别的列是 `facts`。
/// 状态词不放在标题右端：窄列里标题会只剩四五个字。
/// 手机的行里格子窄而矮，还是一排：图标、项目小图形、标题，推进中的右端写时长与要你管的状态词。
struct BoardCardLayout<Icon: View, Title: View, Facts: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    let project: Project?
    var note: String?
    var session: SessionState?
    /// 清单里的一行（待办、已完成）：标题写几行占几行，有旁注才多一行，上下的边也收紧。
    var compact = false
    let icon: Icon
    let title: Title
    let facts: Facts
    let trailing: Trailing
    @Environment(\.boardRow) private var row
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.palette) private var palette

    init(advancing: Bool, pulse: BoardPulse = BoardPulse(), moves: Bool = true, project: Project?, note: String? = nil, session: SessionState? = nil, compact: Bool = false,
         @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title,
         @ViewBuilder facts: () -> Facts = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.advancing = advancing
        self.pulse = pulse
        self.moves = moves
        self.project = project
        self.note = note
        self.session = session
        self.compact = compact
        self.icon = icon()
        self.title = title()
        self.facts = facts()
        self.trailing = trailing()
    }

    var body: some View {
        if !row {
            VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                HStack(alignment: compact ? .top : .firstTextBaseline, spacing: Spacing.item) {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }.font(compact ? TaskMetrics.lineFont : Typography.bodyStrong)
                        if compact, let note { noteLine(note) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 有就地处理的钮时它占右上角（真的那颗浮在卡上，`boardRescue`；这里只留出它的宽）
                    if let session, BoardRescue.kind(of: session) != nil, !compact {
                        BoardRescue(session: session).hidden()
                    } else if let session {
                        AgentMark(session: session, font: TaskMetrics.caption, named: false)
                    }
                    trailing
                }
                if advancing, pulse.shown != nil || note != nil { BoardNow(pulse: pulse, said: note, moves: moves) }
                BoardFoot(glyph: BoardCardMetrics.footGlyph) {
                    if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
                    foot
                }
                .frame(height: advancing ? BoardCardMetrics.vitals : BoardCardMetrics.foot)
            }
            .padding(.vertical, compact ? BoardCardMetrics.compactPad : BoardCardMetrics.pad)
        } else {
            line.frame(maxHeight: .infinity)
        }
    }

    private var foot: some View {
        HStack(spacing: Spacing.glyph) {
            Spacer(minLength: 0)
            if advancing { BoardVitals(pulse: pulse) } else { HStack(spacing: Spacing.glyph) { facts }.fixedSize() }
        }
        .font(TaskMetrics.caption).lineLimit(1)
    }

    private func noteLine(_ note: String) -> some View {
        Text(verbatim: note).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1).readerHidden(true)
    }

    private var line: some View {
        HStack(spacing: BoardCardMetrics.rowGap) {
            Group {
                icon
                if let project { BoardProjectTag(project: project) }
                title
            }
            .font(BoardCardMetrics.rowTitle).lineLimit(BoardCardMetrics.lines(typeSize))
            Spacer(minLength: 0)
            if advancing {
                Group {
                    if pulse.speaks { BoardWord(pulse: pulse) }
                    if let clock = pulse.shown?.clock { TimeSpent(clock: clock) }
                }
                .font(TaskMetrics.caption).lineLimit(1).fixedSize()
            }
            trailing
        }
        .frame(minHeight: BoardCardMetrics.titleRow)
    }
}

/// 卡脚两样：左端项目、右端这一列的事实。事实先占它非要不可的宽，项目名用剩下的、放不下就截；
/// 名字连两三个字都写不下时只留图形。再剩的都归右端。
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
        let width = room < wanted && room < glyph + Self.nameMin ? min(room, glyph) : room
        tag.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        let used = width > 0 ? width + gap : 0
        facts.place(at: CGPoint(x: bounds.minX + used, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: bounds.width - used, height: bounds.height))
    }
}

struct BoardShot: View {
    let shot: CueShown
    let group: String
    /// 成果图做这张卡的主角：铺满卡宽。
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

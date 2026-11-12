import CueStore
import SwiftUI

extension View {
    /// 平放的纸不加模糊阴影：侧栏开合时整面墙每帧重画，靠纸与桌面的明度、色相差把纸托出来。
    func boardCard(_ column: TaskBoard.Column) -> some View { modifier(BoardCardFrame(column: column)) }

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
    /// 列宽到一行写得下最长的那类标题（`BoardWidths.oneLine`）：标题只占一行，不在每张卡里空一行。
    @Entry var boardOneLine = false
}

private struct BoardCardFrame: ViewModifier {
    let column: TaskBoard.Column
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
            .paper(cornerRadius: TaskMetrics.cardRadius, wash: column.paper(palette))
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
            if !row { Text(project.shownName).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1) }
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
/// 列里的卡不管写了几行都占满这几行的高：四列的卡同高，换列时飞的那张不变大小。手机的行里格子的高是行给的，不另留。
/// 否决过不预留（一行写得下的卡就一行高）：同一列的卡高高低低，读起来不齐。
struct BoardCardTitle: View {
    let text: String
    @Environment(\.boardRow) private var row
    @Environment(\.boardOneLine) private var oneLine
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ text: String) { self.text = text }

    var body: some View {
        let lines = typeSize.isAccessibilitySize ? 3 : oneLine ? 1 : 2
        let title = Text(Self.joined(text)).lineLimit(Self.oneWord(text) ? 1 : lines).allowsTightening(true)
        if row {
            title
        } else {
            Text(verbatim: " ").lineLimit(lines, reservesSpace: true).hidden().readerHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) { title }
        }
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
            BoardCardLayout(advancing: true, pulse: pulse, moves: moves, project: project) {
                Group {
                    if let kind = session.agent.known { kind.mark.image } else { Image(.terminal) }
                }
                .font(.system(size: TaskMetrics.cardLead * 0.85)).foregroundStyle(resting ? palette.ink3 : palette.ink2)
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
            } title: {
                BoardCardTitle(name).foregroundStyle(resting ? palette.ink2 : palette.ink)
            }
            .boardCard(.advancing)
        }
        .help(Dotted(project?.shownName, session.agentMark).visible)
        .contextMenu { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
        .accessibilityLabel(Dotted(name, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label, pulse.handoff?.waiting).spoken)
        .accessibilityActions { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
    }
}

/// 列里的卡上下两层：标题，卡脚（左端项目，右端这一列要说的那一样——推进中是线与读数，别的列是 `facts`）。
/// 状态图标不画：卡在哪一列已经说了；状态词不放在标题右端而放在线的右端：窄列里标题会只剩四五个字。
/// 手机的行里格子窄而矮，还是一排：图标、项目小图形、标题，线贴在下沿。
struct BoardCardLayout<Icon: View, Title: View, Facts: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    let project: Project?
    let icon: Icon
    let title: Title
    let facts: Facts
    let trailing: Trailing
    @Environment(\.boardRow) private var row
    @Environment(\.boardArrival) private var arrival
    @Environment(\.dynamicTypeSize) private var typeSize

    init(advancing: Bool, pulse: BoardPulse = BoardPulse(), moves: Bool = true, project: Project?,
         @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title,
         @ViewBuilder facts: () -> Facts = { EmptyView() }, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.advancing = advancing
        self.pulse = pulse
        self.moves = moves
        self.project = project
        self.icon = icon()
        self.title = title()
        self.facts = facts()
        self.trailing = trailing()
    }

    var body: some View {
        if !row {
            VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                HStack(alignment: .top, spacing: Spacing.item) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }.font(TaskMetrics.lineFont)
                    trailing
                }
                BoardFoot {
                    if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
                    foot
                }
                .frame(height: BoardCardMetrics.foot)
            }
            .padding(.vertical, BoardCardMetrics.pad)
        } else if advancing {
            line
                .frame(maxHeight: .infinity)
                .padding(.bottom, WaveStrip.height + BoardCardMetrics.waveBottom)
                .overlay(alignment: .bottomLeading) { rowLine(moves: moves).opacity(lineShown) }
        } else {
            line.frame(maxHeight: .infinity).overlay(alignment: .bottomLeading) { if left { rowLine(moves: false).opacity(leftShown).animation(Motion.fade, value: arrival?.landed) } }
        }
    }

    /// 从推进中飞来的那张先带着线，落下时淡成这一列的事实；飞进推进中的那张落下才画线。线淡得比飞快（`Motion.fade`），不在别的字上多压几帧。
    private var left: Bool { !advancing && arrival?.from == .advancing }
    private var leftShown: Double { arrival?.landed == false ? 1 : 0 }
    private var lineShown: Double { arrival.map { $0.from == .advancing || $0.landed ? 1 : 0 } ?? 1 }

    @ViewBuilder private var foot: some View {
        if advancing {
            BoardLine(pulse: pulse, moves: moves).opacity(lineShown)
        } else {
            HStack(spacing: Spacing.glyph) {
                Spacer(minLength: 0)
                HStack(spacing: Spacing.glyph) { facts }.fixedSize()
            }
            .font(TaskMetrics.caption).lineLimit(1)
            .opacity(left ? 1 - leftShown : 1)
            .overlay { if left { BoardLine(pulse: pulse, moves: false).opacity(leftShown) } }
            .animation(Motion.fade, value: arrival?.landed)
        }
    }

    private func rowLine(moves: Bool) -> some View {
        BoardLine(pulse: pulse, moves: moves)
            .padding(.leading, pulse.word == nil ? TaskMetrics.cardLead + BoardCardMetrics.rowGap : 0)
            .padding(.bottom, BoardCardMetrics.waveBottom)
    }

    private var line: some View {
        HStack(spacing: BoardCardMetrics.rowGap) {
            Group {
                icon
                if let project { BoardProjectTag(project: project) }
                title
            }
            .font(BoardCardMetrics.rowTitle).lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: BoardCardMetrics.titleRow)
    }
}

/// 卡脚两样：左端项目、右端这一列的事实。事实先占它非要不可的宽（读数；推进中的线不算，`BoardLineRow`），项目名用剩下的、放不下就截；
/// 再剩的都归右端（线画在里面）。`HStack` 排不出：线来多少占多少，按优先级排要么项目名被挤没、要么读数被截。
private struct BoardFoot: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tag = subviews[0], facts = subviews[1]
        let wanted = tag.sizeThatFits(.unspecified).width
        let gap = wanted > 0 ? Spacing.item : 0
        let width = min(wanted, max(0, bounds.width - gap - facts.sizeThatFits(.unspecified).width))
        tag.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
        let used = width > 0 ? width + gap : 0
        facts.place(at: CGPoint(x: bounds.minX + used, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: bounds.width - used, height: bounds.height))
    }
}

struct BoardShot: View {
    let shot: CueShown
    let group: String
    let open: (PreviewOpening) -> Void

    var body: some View {
        DeliverableTile(
            preview: shot.preview, label: shot.look, shape: .strip(height: Self.height), captioned: false, zoom: PreviewZoomKey(group: group, preview: shot.id)
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

import CueStore
import SwiftUI

extension View {
    /// 平放的纸不加模糊阴影：侧栏开合时整面墙每帧重画，靠纸与桌面的明度、色相差把纸托出来。
    /// `flat`：清单里的一行（待办、没有成果图的已完成），不垫纸，指针停上去才有淡底。
    func boardCard(_ column: TaskBoard.Column, flat: Bool = false) -> some View { modifier(BoardCardFrame(column: column, flat: flat)) }

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
            .boardCard(.advancing)
        }
        .boardRescue(session)
        .help(Dotted(project?.shownName, session.agentMark).visible)
        .contextMenu { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
        .accessibilityLabel(Dotted(name, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label, pulse.handoff?.waiting).spoken)
        .accessibilityActions { OpenSessionBeside(session: session); SessionActions(session: session, board: agent) }
    }
}

/// 列里的卡上下两层，四列同高（换列时飞的那张不变大小）：
/// 上层固定两行高——标题至多两行，只写了一行时第二行是旁注（`note`：这件事此刻最该知道的一句），右上角是哪家 Agent 的标志；
/// 卡脚左端项目，右端这一列要说的那一样——推进中是线与读数，别的列是 `facts`。
/// 状态图标不画：卡在哪一列已经说了；状态词不放在标题右端而放在线的右端：窄列里标题会只剩四五个字。
/// 否决过：不预留（一行写得下的卡就一行高，同一列高高低低）、预留了空着（每张卡里白占一行）。
/// 手机的行里格子窄而矮，还是一排：图标、项目小图形、标题，线贴在下沿。
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
    @Environment(\.boardArrival) private var arrival
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
                HStack(alignment: .top, spacing: Spacing.item) {
                    if compact {
                        VStack(alignment: .leading, spacing: Spacing.hair) {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }.font(TaskMetrics.lineFont)
                            if let note { noteLine(note) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        BoardTitleBlock {
                            Text(verbatim: Array(repeating: "国", count: BoardCardMetrics.lines(typeSize)).joined(separator: "\n")).hidden().readerHidden(true)
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) { title }
                            noteLine(note ?? "")
                        }
                        .font(TaskMetrics.lineFont)
                        .clipped()
                    }
                    // 有就地处理的钮时它占右上角（真的那颗浮在卡上，`boardRescue`；这里只留出它的宽）
                    if let session, BoardRescue.kind(of: session) != nil, !compact {
                        BoardRescue(session: session).hidden()
                    } else if let session {
                        AgentMark(session: session, font: TaskMetrics.caption, named: false).frame(height: BoardCardMetrics.titleRow)
                    }
                    trailing
                }
                BoardFoot(glyph: BoardCardMetrics.footGlyph) {
                    if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
                    foot
                }
                .frame(height: BoardCardMetrics.foot)
            }
            .padding(.vertical, compact ? BoardCardMetrics.compactPad : BoardCardMetrics.pad)
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

    private func noteLine(_ note: String) -> some View {
        Text(verbatim: note).font(TaskMetrics.caption).foregroundStyle(palette.ink3).lineLimit(1).readerHidden(true)
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
            .font(BoardCardMetrics.rowTitle).lineLimit(BoardCardMetrics.lines(typeSize))
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: BoardCardMetrics.titleRow)
    }
}

/// 三样：两行高的占位（按中文排，中文行比西文行高）、标题、旁注。标题只占了一行时旁注排在第二行；占了两行就排到块外、被裁掉。
private struct BoardTitleBlock: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: subviews[0].sizeThatFits(.unspecified).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = ProposedViewSize(width: bounds.width, height: nil)
        let title = subviews[1], note = subviews[2]
        let noteHeight = note.sizeThatFits(width).height
        let fits = title.sizeThatFits(width).height + noteHeight <= bounds.height + 0.5
        subviews[0].place(at: bounds.origin, proposal: width)
        title.place(at: bounds.origin, proposal: width)
        note.place(at: CGPoint(x: bounds.minX, y: fits ? bounds.maxY - noteHeight : bounds.maxY + noteHeight), proposal: width)
    }
}

/// 卡脚两样：左端项目、右端这一列的事实。事实先占它非要不可的宽（读数；推进中的线不算，`BoardLineRow`），项目名用剩下的、放不下就截；
/// 名字连两三个字都写不下时只留图形。再剩的都归右端（线画在里面）。`HStack` 排不出：线来多少占多少，按优先级排要么项目名被挤没、要么读数被截。
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

/// 卡住的会话就地处理的那一颗：额度用完去管理用量，出错的重试，上下文快满的压缩（规则同会话页的 `FailureDock`、`ContextGauge`）。
/// 原因卡上一直写着（线右端的状态词），这颗是中性的小钮，不加红框。
struct BoardRescue: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace

    enum Kind { case usage(URL), retry, compact }

    static func kind(of session: SessionState) -> Kind? {
        if let url = session.usageURL { return .usage(url) }
        if session.canRetry { return .retry }
        if session.context.flatMap(ContextMeter.init)?.level == .critical { return .compact }
        return nil
    }

    var body: some View {
        Group {
            switch Self.kind(of: session) {
            case .usage(let url): Link("管理用量", destination: url)
            case .retry: Button("重试") { workspace.retry(session) }
            case .compact: Button("现在压缩") { workspace.speak("/compact", to: .session(session, mode: .command)) }
            case nil: EmptyView()
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .inline))
        .fixedSize()
    }
}

extension View {
    /// 浮在卡的右上角、不放进卡里：会话卡整张是一颗按钮（`BoardLink`），钮里不套钮。
    func boardRescue(_ session: SessionState?) -> some View {
        overlay(alignment: .topTrailing) {
            if let session, BoardRescue.kind(of: session) != nil {
                BoardRescue(session: session).padding(.trailing, TaskMetrics.cardPadding).padding(.top, BoardCardMetrics.pad)
            }
        }
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

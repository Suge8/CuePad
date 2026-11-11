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
    @Entry var boardTitle = BoardTitle()
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

/// 看全部项目时才画：选了项目范围时范围已经说了。
struct BoardProjectGlyph: View {
    let project: Project
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif
    @Environment(\.boardTitle) private var band

    var body: some View {
        if band.glyph {
            ProjectGlyph(project: project, size: TaskMetrics.cardGlyph)
                .help(project.shownName)
            #if os(macOS)
                .onHover { workspace.hoverProject(project.id, $0) }
                .presetHover(Binding { false } set: { if $0 { workspace.hoverProject(project.id, true) } })
            #endif
        }
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
/// 整个标题只是一个拉丁词（没有空格、没有汉字）时只排一行，放不下先收字距、再截断，不按字母折行。中文照常按字折，至多所在的列给的行数（`boardTitle`）。
/// 几个拉丁词里有一个比一行还长时系统仍会在词中间折：标题里少见，不为它另排。
struct BoardCardTitle: View {
    let text: String
    @Environment(\.boardTitle) private var band

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(Self.joined(text)).lineLimit(Self.oneWord(text) ? 1 : band.lines).allowsTightening(true)
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
            BoardCardLayout(advancing: true, pulse: pulse, moves: moves) {
                Group {
                    if let kind = session.agent.known { kind.mark.image } else { Image(.terminal) }
                }
                .font(.system(size: TaskMetrics.cardLead * 0.85)).foregroundStyle(resting ? palette.ink3 : palette.ink2)
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
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

/// 状态词不放在标题右端而放在线的右端：窄列里标题会只剩四五个字。
struct BoardCardLayout<Lead: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    let lead: Lead
    let trailing: Trailing
    @Environment(\.boardRow) private var row
    @Environment(\.boardTitle) private var titleBand
    @Environment(\.boardArrival) private var arrival

    init(advancing: Bool, pulse: BoardPulse = BoardPulse(), moves: Bool = true,
         @ViewBuilder lead: () -> Lead, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.advancing = advancing
        self.pulse = pulse
        self.moves = moves
        self.lead = lead()
        self.trailing = trailing()
    }

    var body: some View {
        if advancing { withLine } else if row { title.frame(maxHeight: .infinity).overlay(alignment: .bottomLeading) { leftLine } } else {
            title.padding(.vertical, titleBand.padding).overlay(alignment: .bottomLeading) { leftLine }
        }
    }

    /// 新的一列没给线留高，线淡得比飞快（`Motion.fade`），不在字上多压几帧。
    @ViewBuilder private var leftLine: some View {
        if let arrival, arrival.from == .advancing {
            line(moves: false)
                .opacity(arrival.landed ? 0 : 1)
                .animation(Motion.fade, value: arrival.landed)
        }
    }

    private func line(moves: Bool) -> some View {
        BoardLine(pulse: pulse, moves: moves)
            .padding(.leading, pulse.word == nil ? TaskMetrics.cardLead + gap : 0)
            .padding(.bottom, BoardCardMetrics.waveBottom)
    }

    private var title: some View {
        HStack(spacing: gap) {
            lead.font(row ? BoardCardMetrics.rowTitle : TaskMetrics.lineFont).lineLimit(titleBand.lines)
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: BoardCardMetrics.titleRow)
    }

    private var withLine: some View {
        title
            .frame(maxHeight: row ? .infinity : nil)
            .padding(.top, row ? 0 : BoardCardMetrics.titleTop)
            .padding(.bottom, (row ? 0 : BoardCardMetrics.waveGap) + WaveStrip.height + BoardCardMetrics.waveBottom)
            .overlay(alignment: .bottomLeading) {
                line(moves: moves).opacity(arrival.map { $0.from == .advancing || $0.landed ? 1 : 0 } ?? 1)
            }
    }

    private var gap: CGFloat { row ? BoardCardMetrics.rowGap : BoardCardMetrics.leadGap }
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

import CueStore
import SwiftUI

extension View {
    /// 看板上一张卡的外形：纸面（`paper`），纸色随所在的列（`TaskBoard.Column.paper`，四列分轻重），多高由里面的排法定（`BoardCardLayout`：同一列的卡一样宽，就一样高；
    /// 手机竖版看板里铺满行给的格），左右内边距与圆角见 `TaskMetrics`。平放的纸不加模糊阴影（侧栏开合时整面墙每帧重画，`paper` 的注释）：靠纸与桌面的明度、色相差把纸托出来。
    func boardCard(_ column: TaskBoard.Column) -> some View { modifier(BoardCardFrame(column: column)) }

    /// 项目联动（Mac）：指针停在侧栏的项目行或卡上的项目小图形上时（`Workspace.hoveredProject`），别的项目的卡淡下去，这个项目的不动。
    /// 只这一个小修饰读它：指针换项目时重算的是各卡的透明度，不是整张卡。没有项目的（Cue 的一般提问）跟着淡。
    func boardDim(project: UUID?) -> some View {
        #if os(macOS)
        modifier(BoardDim(project: project))
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// 卡在手机竖版看板（`PhoneBoard`）的一行里：卡铺满行给的那一格（格多高只由行高定，`BoardRowLane`）、标题小一档；
    /// 列里的卡（Mac、宽屏 iPad、iPhone 横屏）不是。
    @Entry var boardRow = false
    /// 卡标题留几行、多高：所在的列或行按卡宽与字号算一次（`BoardCardMetrics.title`），同一列、同一行的卡都一样。
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
                // 换列飞来时盖着原来那一列的纸色，随着飞淡掉（`boardFlight`）：纸色在飞的途中调过来，不在起飞那一下换
                if let arrival {
                    RoundedRectangle(cornerRadius: TaskMetrics.cardRadius, style: .continuous)
                        .fill(arrival.from.paper(palette) ?? palette.paper).opacity(arrival.landed ? 0 : 1)
                }
            }
            .paper(radius: TaskMetrics.cardRadius, wash: column.paper(palette))
            .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
    }
}

#if os(macOS)
private struct BoardDim: ViewModifier {
    let project: UUID?
    @Environment(Workspace.self) private var workspace

    /// 淡下去的卡还看得出是什么，又一眼分得出不是这个项目的。
    private static let dimmed = 0.35

    func body(content: Content) -> some View {
        let hovered = workspace.hoveredProject
        content
            .opacity(hovered.map { $0 == project } ?? true ? 1 : Self.dimmed)
            .animation(Motion.fade, value: hovered)
    }
}
#endif

/// 卡上标题前的项目小图形：看全部项目时才画（选了项目范围时范围已经说了）。Mac 上指针停在它上面是项目联动（`boardDim`），悬停提示写项目名。
struct BoardProjectGlyph: View {
    let project: Project
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif

    var body: some View {
        ProjectGlyph(project: project, size: TaskMetrics.cardGlyph)
            .help(project.shownName)
        #if os(macOS)
            .onHover { workspace.hoverProject(project.id, $0) }
            .presetHover(Binding { false } set: { if $0 { workspace.hoverProject(project.id, true) } })
        #endif
    }
}

#if os(macOS)
extension Workspace {
    /// 指针进出一个项目（侧栏的项目行、卡上的项目小图形）：进来设成它，出去时还是它才清掉——指针从一处直接挪到另一处时，先进后出的顺序不定。
    func hoverProject(_ project: UUID, _ inside: Bool) {
        if inside { hoveredProject = project } else if hoveredProject == project { hoveredProject = nil }
    }
}
#endif

/// 推进中一个没绑没做完的任务的活会话（终端里开的、"新会话"、只有已完成的事绑着的）：同任务卡（`BoardTaskCard`）的语法——
/// 开头是这家 Agent 的品牌标（`AgentKind.mark`，任务是完成圈），标题是会话名，下沿是那条线（`BoardLine`，按 `BoardPulse` 画，右端写此刻状态多久与要你管的状态词），
/// 看全部项目时标题前是它归处的项目小图形；悬停提示写项目与哪家 Agent。点了打开会话。
struct BoardSessionCard: View {
    let session: PiSessionState
    let project: Project?
    var moves = true
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let pulse = workspace.pulse(of: session)
        let resting = pulse.tier == .resting
        BoardLink(to: .session(session)) {
            BoardCardLayout(advancing: true, pulse: pulse, moves: moves) {
                Group {
                    if let kind = session.agent.known { kind.mark.image } else { Image(.terminal) }
                }
                .font(.system(size: TaskMetrics.cardLead * 0.85)).foregroundStyle(resting ? palette.ink3 : palette.ink2)
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                Text(session.title).foregroundStyle(resting ? palette.ink2 : palette.ink)
            }
            .boardCard(.advancing)
        }
        .help(Dotted(project?.shownName, session.agentMark).visible)
        .accessibilityLabel(Dotted(session.title, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label, pulse.handoff?.waiting).spoken)
    }
}

/// 卡里的排法（看板上所有的卡同一种）：开头记号、项目小图形与标题一行带，右端是调用处给的尾巴；
/// 推进中的卡标题贴上沿，下面是那条线（`BoardLine`，时长与要你管的状态词在线的右端）：标题一整带都给字（状态词放在标题右端时，窄列里标题只剩四五个字）。
/// 卡多高只由这里加出来：上下留白、标题（按所在的列或行给的行数与留白，`boardTitle`：只有一行字的卡也一样高）、线。
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

    /// 从推进中飞出来的卡（`boardArrival`）：起飞时还带着那条线（调用处照旧给 `pulse`），随即淡掉——线不在起飞那一下没了。
    /// 新的一列没给线留高，淡得比飞快（`Motion.fade`），不在字上多压几帧。
    @ViewBuilder private var leftLine: some View {
        if let arrival, arrival.from == .advancing {
            line(moves: false)
                .opacity(arrival.landed ? 0 : 1)
                .animation(Motion.fade, value: arrival.landed)
        }
    }

    private func line(moves: Bool) -> some View {
        BoardLine(pulse: pulse, moves: moves)
            .padding(.leading, TaskMetrics.cardLead + gap)
            .padding(.bottom, BoardCardMetrics.waveBottom)
    }

    private var title: some View {
        HStack(spacing: gap) {
            lead.font(row ? BoardCardMetrics.rowTitle : TaskMetrics.lineFont).lineLimit(titleBand.lines)
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: titleBand.height)
    }

    /// 推进中：标题下面让出线那一截，线压在卡的下沿、从标题的字下面起。列里标题贴上沿、线离它 `waveGap`；
    /// 手机的行里卡铺满格，标题在线上面那一截里竖直居中。
    private var withLine: some View {
        title
            .frame(maxHeight: row ? .infinity : nil)
            .padding(.top, row ? 0 : BoardCardMetrics.titleTop)
            .padding(.bottom, (row ? 0 : BoardCardMetrics.waveGap) + WaveStrip.height + BoardCardMetrics.waveBottom)
            .overlay(alignment: .bottomLeading) {
                // 从别的列飞进推进中（`boardArrival`）：线随着飞淡出来，不在起飞那一下冒出来
                line(moves: moves).opacity(arrival.map { $0.from == .advancing || $0.landed ? 1 : 0 } ?? 1)
            }
    }

    private var gap: CGFloat { row ? BoardCardMetrics.rowGap : Self.gap }

    static var gap: CGFloat { 8 }
}

/// 已完成卡尾的成果图：一张小缩略图（同一种交付物缩略图 `DeliverableTile`），点开全屏看（`previewPresenter`）。
struct BoardShot: View {
    let shot: CueShown
    let group: String
    let open: (PreviewOpening) -> Void

    var body: some View {
        DeliverableTile(
            preview: shot.preview, label: shot.look, shape: .strip(height: Self.height), captioned: false, zoom: PreviewZoomKey(group: group, preview: shot.id)
        ) { _ in open(Self.opening(shot, group: group)) }
    }

    /// 点开它：全屏只这一张，页顶写看什么，底栏对 Cue 说（同结果卡）。
    static func opening(_ shot: CueShown, group: String) -> PreviewOpening {
        PreviewOpening(preview: shot.preview, batch: [shot.preview], group: group, looks: [shot.id: shot.look])
    }

    #if os(macOS)
    private static let height: CGFloat = 28
    #else
    private static let height: CGFloat = 34
    #endif
}

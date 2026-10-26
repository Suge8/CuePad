import CueStore
import SwiftUI

extension View {
    /// 看板上一张卡的外形（四列同一种）：纸面（`paper`），多高由里面的排法定（`BoardCardLayout`：同一列的卡一样宽，就一样高；手机竖版看板里铺满行给的格），
    /// 左右内边距与圆角见 `TaskMetrics`。平放的纸不加模糊阴影（侧栏开合时整面墙每帧重画，`paper` 的注释）：靠纸与桌面（托盘）的明度差把纸托出来。
    func boardCard() -> some View { modifier(BoardCardFrame()) }

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
    @Environment(\.boardRow) private var row

    func body(content: Content) -> some View {
        content.padding(.horizontal, row ? BoardCardMetrics.rowPadding : TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: row ? .infinity : nil, alignment: .leading)
            .paper(radius: TaskMetrics.cardRadius)
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
            .animation(HandOff.quick, value: hovered)
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
/// 开头是这家 Agent 的品牌标（`AgentKind.mark`，任务是完成圈），标题是会话名，下沿的线与线右端的状态词按 `BoardPulse` 写（要你管的写状态词、线停住，在跑的线在动），
/// 看全部项目时标题前是它归处的项目小图形；悬停提示写项目、此刻状态多久与哪家 Agent。点了打开会话。
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
            .boardCard()
        }
        .help(Dotted(project?.shownName, PiClock.duration(Date.now.timeIntervalSince(pulse.shown?.clock?.since ?? session.stateSince)), session.agentMark).visible)
        .accessibilityLabel(Dotted(session.title, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label).spoken)
    }
}

/// 卡里的排法（看板上所有的卡同一种）：开头记号、项目小图形与标题一行带，右端是调用处给的尾巴；
/// 推进中的卡标题贴上沿，下面是那条线（`BoardWave`），有子任务的线下面再分段（`BoardSteps`），要你管的状态词在线的右端：
/// 标题一整带都给字（状态词放在标题右端时，窄列里标题只剩四五个字）。卡多高只由这里加出来：上下留白、标题（按所在的列或行给的行数留足，
/// `boardTitle`：只有一行字的卡也一样高）、线。
struct BoardCardLayout<Lead: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    var steps: TaskProgress?
    let lead: Lead
    let trailing: Trailing
    @Environment(\.palette) private var palette
    @Environment(\.boardRow) private var row
    @Environment(\.boardTitle) private var titleBand

    init(advancing: Bool, pulse: BoardPulse = BoardPulse(), moves: Bool = true, steps: TaskProgress? = nil,
         @ViewBuilder lead: () -> Lead, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.advancing = advancing
        self.pulse = pulse
        self.moves = moves
        self.steps = steps
        self.lead = lead()
        self.trailing = trailing()
    }

    var body: some View {
        if advancing { withWave } else if row { title.frame(maxHeight: .infinity) } else { title.padding(.vertical, BoardCardMetrics.titlePadding) }
    }

    private var title: some View {
        HStack(spacing: gap) {
            lead.font(row ? BoardCardMetrics.rowTitle : TaskMetrics.lineFont).lineLimit(titleBand.lines)
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: titleBand.height)
    }

    /// 推进中：标题下面让出线那一截，线压在卡的下沿。列里标题贴上沿、线离它 `waveGap`，带子代理细轨的线往下多占几点、不撑高卡；
    /// 手机的行里卡铺满格，标题在线上面那一截里竖直居中，细轨往上占。子任务的分段压在线那一格的底边，线最低处也在它上面。
    private var withWave: some View {
        title
            .frame(maxHeight: row ? .infinity : nil)
            .padding(.top, row ? 0 : BoardCardMetrics.titleTop)
            .padding(.bottom, (row ? 0 : BoardCardMetrics.waveGap) + WaveStrip.height + BoardCardMetrics.waveBottom)
            .overlay(alignment: .bottomLeading) {
                waveLine.fixedSize(horizontal: false, vertical: true)
                    .frame(height: WaveStrip.height, alignment: row ? .bottom : .top)
                    .padding(.leading, TaskMetrics.cardLead + gap)
                    .padding(.bottom, BoardCardMetrics.waveBottom)
            }
    }

    private var gap: CGFloat { row ? BoardCardMetrics.rowGap : Self.gap }

    /// 下沿那一行：线，右端是要你管的状态词。
    private var waveLine: some View {
        HStack(alignment: .center, spacing: Self.gap) {
            wave
            if pulse.speaks { word }
        }
    }

    private var wave: some View {
        ZStack(alignment: .bottomLeading) {
            BoardWave(trace: pulse.trace, moves: moves)
            if let steps, steps.total >= 2 { BoardSteps(steps: steps) }
        }
        .frame(minHeight: WaveStrip.height, alignment: .bottomLeading)
    }

    /// 要你管的状态词：会话的状态词，或快满的上下文。
    @ViewBuilder private var word: some View {
        if let shown = pulse.shown, shown.speaksOnTask {
            Text(shown.label).font(TaskMetrics.caption.weight(.semibold)).foregroundStyle(shown.labelTint(palette)).fixedSize()
        } else if let meter = pulse.fullContext {
            ContextFact(meter: meter).font(TaskMetrics.caption).fixedSize()
        }
    }

    static var gap: CGFloat { 8 }
}

/// 推进中有子任务的卡下沿的分段：一步一段，做完的墨色、此刻那一步靛青、没到的轨道色。
private struct BoardSteps: View {
    let steps: TaskProgress
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<steps.total, id: \.self) { index in
                Capsule().fill(index < steps.done ? palette.ink : index == steps.done ? palette.signature : palette.track)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
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

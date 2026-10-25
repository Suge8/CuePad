import CueStore
import SwiftUI

extension View {
    /// 看板上一张卡的外形（四列同一种）：纸面（`paper`），同一种卡一样高（`BoardCardMetrics`：推进中带线的卡 `advancingHeight`，其余 `TaskMetrics.cardHeight`；手机竖版看板里铺满行给的格），
    /// 左右内边距与圆角见 `TaskMetrics`。平放的纸不加模糊阴影（侧栏开合时整面墙每帧重画，`paper` 的注释）：靠纸与桌面（托盘）的明度差把纸托出来。
    func boardCard(advancing: Bool) -> some View { modifier(BoardCardFrame(advancing: advancing)) }

    /// 卡上的标题：一行；手机竖版看板（`boardRow`）里小一档、可折成两行。`wraps`：等你列的卡（名字要先读得出，右端没有占地方的状态词）处处可折两行。
    func boardTitle(wraps: Bool = false) -> some View { modifier(BoardTitleStyle(wraps: wraps)) }

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
    /// Mac 与宽屏 iPad 不是。
    @Entry var boardRow = false
}

private struct BoardCardFrame: ViewModifier {
    let advancing: Bool
    @Environment(\.boardRow) private var row

    func body(content: Content) -> some View {
        let height: CGFloat? = row ? nil : advancing ? BoardCardMetrics.advancingHeight : TaskMetrics.cardHeight
        content.padding(.horizontal, row ? BoardCardMetrics.rowPadding : TaskMetrics.cardPadding)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height ?? .infinity, alignment: .leading)
            .paper(radius: TaskMetrics.cardRadius)
            .contentShape(.rect(cornerRadius: TaskMetrics.cardRadius, style: .continuous))
    }
}

private struct BoardTitleStyle: ViewModifier {
    let wraps: Bool
    @Environment(\.boardRow) private var row

    func body(content: Content) -> some View {
        content.font(row ? BoardCardMetrics.rowTitle : TaskMetrics.lineFont).lineLimit(row || wraps ? 2 : 1)
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
                Text(session.title).boardTitle().foregroundStyle(resting ? palette.ink2 : palette.ink)
            }
            .boardCard(advancing: true)
        }
        .help(Dotted(project?.shownName, PiClock.duration(Date.now.timeIntervalSince(pulse.shown?.clock?.since ?? session.stateSince)), session.agentMark).visible)
        .accessibilityLabel(Dotted(session.title, pulse.fullContext.map { $0.help.spoken } ?? pulse.shown?.label).spoken)
    }
}

/// 卡里的排法（任务卡、会话卡同一种）：一行开头记号、项目小图形与标题，右端是调用处给的尾巴；
/// 推进中的卡标题贴上沿，下沿是那条线（`BoardWave`），有子任务的线下面再分段（`BoardSteps`），要你管的状态词在线的右端：
/// 标题一整行都给字（状态词放在标题右端时，窄列里标题只剩四五个字）；别的列的卡标题竖直居中。
struct BoardCardLayout<Lead: View, Trailing: View>: View {
    let advancing: Bool
    var pulse = BoardPulse()
    var moves = true
    var steps: TaskProgress?
    let lead: Lead
    let trailing: Trailing
    @Environment(\.palette) private var palette
    @Environment(\.boardRow) private var row

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
        if row, advancing { rowAdvancing } else { standard }
    }

    private var title: some View {
        HStack(spacing: row ? BoardCardMetrics.rowGap : Self.gap) {
            lead
            Spacer(minLength: 0)
            trailing
        }
    }

    private var standard: some View {
        title
            .frame(height: advancing ? BoardCardMetrics.titleRow : nil)
            .frame(maxHeight: .infinity, alignment: advancing ? .top : .center)
            .padding(.top, advancing ? BoardCardMetrics.titleTop : 0)
            .overlay(alignment: .topLeading) {
                if advancing {
                    // 线从离标题 `waveGap` 处起（带子代理细轨的线往下多占几点，不往上挤）；子任务的分段压在线那一格的底边，线最低处也在它上面
                    waveLine.padding(.leading, TaskMetrics.cardLead + Self.gap).padding(.top, BoardCardMetrics.waveTop)
                }
            }
    }

    /// 竖版看板里的推进中：卡窄，标题可折两行、在线上面那一截里竖直居中。
    private var rowAdvancing: some View {
        title
            .frame(maxHeight: .infinity)
            .padding(.bottom, WaveStrip.height + BoardCardMetrics.waveBottom)
            .overlay(alignment: .bottomLeading) {
                waveLine
                    .padding(.leading, TaskMetrics.cardLead + BoardCardMetrics.rowGap)
                    .padding(.bottom, BoardCardMetrics.waveBottom)
            }
    }

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
        PreviewOpening(preview: shot.preview, batch: [shot.preview], group: group, reply: .cue, looks: [shot.id: shot.look])
    }

    #if os(macOS)
    private static let height: CGFloat = 28
    #else
    private static let height: CGFloat = 34
    #endif
}

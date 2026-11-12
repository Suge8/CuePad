import CueStore
import SwiftUI

/// 等你列是全页唯一要你动手的地方，一次只摊开一张（`focal`）：它与页面反色（浅色里是深的、深色里是浅的），问的那句用大字，成果图与选项都在卡上，当场答。
/// 别的收成一张小卡，点一下换它摊开；摊开的那张点问句进会话。否决过：每张都摊开（三四件等你时一列全是选项，分不出先看哪件）。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    var focal = false
    var focus: () -> Void = {}
    var openShot: (PreviewOpening) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.boardRow) private var row
    @Environment(\.colorScheme) private var scheme
    @Environment(\.palette) private var palette
    /// 列窄时（侧栏与 Cue 都开着的小窗）摊开的那张收一档：边距与问句的字号都小一号，不然一句话折成五六行。
    @State private var narrow = false
    nonisolated private static let roomy: CGFloat = 240

    var body: some View {
        Group {
            if row {
                link { rowFace.boardCard(.waiting) }
            } else if focal {
                // 选项不放进打开会话的那颗钮里：钮里不套钮
                VStack(alignment: .leading, spacing: narrow ? Spacing.group : Spacing.block) {
                    link { BoardWaitFace(held: held, project: project, ask: ask, size: narrow ? .focalNarrow : .focal) }
                    if let shot = held.item?.shot { BoardShot(shot: shot, group: held.id, hero: true, open: openShot) }
                    WaitAnswer(wait: .session(held.session, task: held.item?.id), leading: true)
                }
                .padding(narrow ? Spacing.group : Spacing.panel)
                .modifier(FocalGround())
                .onGeometryChange(for: Bool.self) { $0.size.width < Self.roomy } action: { narrow = $0 }
                .environment(\.colorScheme, scheme == .dark ? .light : .dark)
            } else {
                Button(action: focus) {
                    BoardWaitFace(held: held, project: project, ask: ask, size: .folded).padding(.vertical, BoardCardMetrics.pad).boardCard(.waiting)
                }
                .buttonStyle(PressStyle(.card))
                .accessibilityLabel(spoken)
                .accessibilityHint("展开作答")
            }
        }
        .contextMenu { menu }
        .boardDim(project: held.project)
    }

    private var spoken: String { Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复"), ask).spoken }

    private func link(@ViewBuilder _ label: () -> some View) -> some View {
        let label = label()
        return BoardLink(to: held.session) {
            #if os(macOS)
            // 悬停提示里等了多久跟着走：到下一次换字的时刻（`SessionClock.Waited`）只重画卡面，挂着菜单的那一层不随时间重建
            Moments(next: SessionClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in label.help(tip(at: now)) }
            #else
            label
            #endif
        }
        .accessibilityLabel(spoken)
        .accessibilityActions { menu }
    }

    private var rowFace: some View {
        BoardCardLayout(advancing: false, project: project) {
            StateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
        } title: {
            if held.item?.task.isPinned == true { BoardPin() }
            BoardCardTitle(held.title).foregroundStyle(palette.ink)
        }
    }

    /// 等你的是哪一句：拍板是它问的那句，待回复是它最后说的那句的头一句。
    private var ask: String? {
        held.deciding ? SessionProgress.firstLine(held.session.question?.displayText ?? held.session.detail) : SessionProgress.firstSentence(held.session.lastReply)
    }

    @ViewBuilder private var menu: some View {
        OpenSessionBeside(session: held.session)
        if let item = held.item {
            CardActions(card: item.task, leaf: item.steps == nil, opens: true, session: held.session)
        } else {
            SessionActions(session: held.session, board: SessionListItem(state: held.session))
        }
    }

    #if os(macOS)
    private func tip(at now: Date) -> String {
        Dotted(
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : String(localized: "待回复"),
            SessionClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

/// 上面一行小字：拍板还是待回复、项目、哪个会话、等了多久、哪家 Agent；下面是等你的那一句。
private struct BoardWaitFace: View {
    let held: TaskBoard.Held
    let project: Project?
    let ask: String?
    let size: Size
    @Environment(\.palette) private var palette

    enum Size { case folded, focalNarrow, focal }

    var body: some View {
        if size == .folded { folded } else { open }
    }

    /// 收着的小卡与推进中的卡同一副骨架（`BoardCardLayout`）：名字与 Agent、状态标带等你的那一句、项目与等了多久。
    private var folded: some View {
        VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    if held.item?.task.isPinned == true { BoardPin() }
                    BoardCardTitle(held.title).foregroundStyle(palette.ink)
                }
                .font(Typography.bodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                AgentMark(session: held.session, font: TaskMetrics.caption, named: false)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                StateDot(shown: SessionShown(status: held.deciding ? .asking : .awaitsReply), size: BoardNow.mark)
                Text("\(kind.fontWeight(.semibold).foregroundStyle(palette.waiting)) \(Text(verbatim: ask ?? "").foregroundStyle(palette.ink2))")
                    .lineLimit(Self.foldedLines).multilineTextAlignment(.leading)
            }
            BoardFoot(glyph: BoardCardMetrics.footGlyph) {
                if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
                HStack { Spacer(minLength: 0); waited }
            }
            .frame(height: BoardCardMetrics.vitals)
        }
        .font(TaskMetrics.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var kind: Text { Text(held.deciding ? "拍板" : "待回复") }
    private var waited: some View {
        LiveText(style: SessionClock.Waited(since: held.session.stateSince)).foregroundStyle(palette.ink3).lineLimit(1).fixedSize()
    }

    private var open: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            // 放不下就少写：先去掉会话名与 Agent，再去掉项目——哪种与等了多久一直在
            ViewThatFits(in: .horizontal) {
                meta(name: true, project: true)
                meta(name: false, project: true)
                meta(name: false, project: false)
            }
            .font(TaskMetrics.caption)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                if held.item?.task.isPinned == true { BoardPin() }
                Text(verbatim: ask ?? held.title).font(font).foregroundStyle(palette.ink)
                    .lineLimit(Self.focalLines).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func meta(name: Bool, project shown: Bool) -> some View {
        HStack(spacing: Spacing.glyph) {
            kind.fontWeight(.semibold).foregroundStyle(palette.waiting).fixedSize()
            // 这一行窄：项目只画图形（名字在悬停提示里），地方留给会话名
            if shown, let project { ProjectGlyph(project: project, size: TaskMetrics.cardGlyph).help(project.shownName) }
            if name, ask != nil { Text(verbatim: held.title).foregroundStyle(palette.ink3).lineLimit(1).frame(minWidth: Self.nameMin, alignment: .leading) }
            Spacer(minLength: Spacing.item)
            waited
            if name { AgentMark(session: held.session, font: TaskMetrics.caption, named: false).fixedSize() }
        }
    }

    private var font: Font { size == .focalNarrow ? Typography.title : Typography.heading }

    private static let focalLines = 6
    private static let foldedLines = 2
    /// 会话名至少写得下三四个字才写，不然只剩一个"…"。
    private static let nameMin: CGFloat = 48
}

/// 反色的那一面：读的是已经翻过来的配色（调用方在它外面换了 `colorScheme`），所以这里的桌面色就是对面那套的。
/// 全页只这一张带投影（别的纸平放不加，见 `boardCard`），用矮的那档：`panel` 那档晕得开，往上漫到列头垫的那条桌面色后面，露出一块方印。
private struct FocalGround: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: Radius.field).fill(palette.desk).elevation(.lifted)
        }
        .contentShape(.rect(cornerRadius: Radius.field))
    }
}

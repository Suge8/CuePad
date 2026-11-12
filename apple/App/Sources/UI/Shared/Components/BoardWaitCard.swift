import CueStore
import SwiftUI

struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.boardRow) private var row
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if row {
                link { rowFace.boardCard(.waiting) }
            } else {
                // 能就地答的题，选项在卡上（同 Cue 页的拍板卡，`WaitAnswer`）。选项不放进打开会话的那颗钮里：钮里不套钮
                VStack(alignment: .leading, spacing: Spacing.item) {
                    link { face }
                    if held.deciding, held.session.answerableQuestion != nil { WaitAnswer(wait: .session(held.session, task: held.item?.id), leading: true) }
                    foot
                }
                .padding(.vertical, BoardCardMetrics.pad)
                .boardCard(.waiting)
            }
        }
        .contextMenu { menu }
        .boardDim(project: held.project)
    }

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
        .accessibilityLabel(Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复"), ask).spoken)
        .accessibilityActions { menu }
    }

    /// 这一列是全页唯一要你动手的地方：等你的那一句是标题，哪个会话退成上面一行小字。
    private var face: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                Text(held.deciding ? "拍板" : "待回复").fontWeight(.semibold).foregroundStyle(held.deciding ? palette.waiting : palette.ink2).fixedSize()
                if ask != nil { Text(verbatim: held.title).foregroundStyle(palette.ink3).lineLimit(1) }
                Spacer(minLength: Spacing.item)
                AgentMark(session: held.session, font: TaskMetrics.caption, named: false)
            }
            .font(TaskMetrics.caption)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                if held.item?.task.isPinned == true { BoardPin() }
                Text(verbatim: ask ?? held.title).font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(Self.askLines).multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var foot: some View {
        BoardFoot(glyph: BoardCardMetrics.footGlyph) {
            if let project { BoardProjectTag(project: project) } else { Color.clear.frame(width: 0) }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LiveText(style: SessionClock.Waited(since: held.session.stateSince)).foregroundStyle(palette.ink3).fixedSize()
            }
            .font(TaskMetrics.caption).lineLimit(1)
        }
        .frame(height: BoardCardMetrics.foot)
    }

    private static let askLines = 4

    private var rowFace: some View {
        BoardCardLayout(advancing: false, pulse: leftPulse, project: project) {
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

    private var leftPulse: BoardPulse {
        guard arrival?.from == .advancing else { return BoardPulse() }
        return workspace.pulse(of: held.item?.agent ?? SessionListItem(state: held.session))
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

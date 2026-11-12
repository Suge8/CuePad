import CueStore
import SwiftUI

struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    var body: some View {
        BoardLink(to: held.session) {
            #if os(macOS)
            // 悬停提示里等了多久跟着走：到下一次换字的时刻（`SessionClock.Waited`）只重画卡面，挂着菜单的那一层不随时间重建
            Moments(next: SessionClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in face.help(tip(at: now)) }
            #else
            face
            #endif
        }
        .contextMenu { menu }
        .accessibilityLabel(Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复")).spoken)
        .accessibilityActions { menu }
        .boardDim(project: held.project)
    }

    private var face: some View {
        BoardCardLayout(advancing: false, pulse: leftPulse, project: project, note: ask, session: held.session) {
            StateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
        } title: {
            if held.item?.task.isPinned == true { BoardPin() }
            BoardCardTitle(held.title, lines: ask == nil ? nil : 1).foregroundStyle(palette.ink)
        } facts: {
            // 拍板与待回复原来靠图标分，现在写成字；等了多久跟着走
            Text(held.deciding ? "拍板" : "待回复").fontWeight(.semibold).foregroundStyle(held.deciding ? palette.waiting : palette.ink2)
            LiveText(style: SessionClock.Elapsed(since: held.session.stateSince)).foregroundStyle(palette.ink3)
        }
        .boardCard(.waiting)
    }

    /// 等你的是哪一句：拍板是它问的那句，待回复是它最后说的那句的头一句。卡上它比名字要紧，标题让成一行。
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

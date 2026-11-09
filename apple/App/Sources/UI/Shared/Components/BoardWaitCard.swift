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
            // 悬停提示里等了多久跟着走：到下一次换字的时刻（`PiClock.Waited`）只重画卡面，挂着菜单的那一层不随时间重建
            Moments(next: PiClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in face.help(tip(at: now)) }
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
        BoardCardLayout(advancing: false, pulse: leftPulse) {
            PiStateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
                .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
            if let project { BoardProjectGlyph(project: project) }
            if held.item?.task.isPinned == true { BoardPin() }
            BoardCardTitle(held.title).foregroundStyle(palette.ink)
        }
        .boardCard(.waiting)
    }

    @ViewBuilder private var menu: some View {
        OpenSessionBeside(session: held.session)
        if let item = held.item {
            CardActions(card: item.task, leaf: item.steps == nil, opens: true, session: held.session)
        } else {
            SessionActions(session: held.session, board: PiSessionListItem(state: held.session))
        }
    }

    private var leftPulse: BoardPulse {
        guard arrival?.from == .advancing else { return BoardPulse() }
        return workspace.pulse(of: held.item?.agent ?? PiSessionListItem(state: held.session))
    }

    #if os(macOS)
    private func tip(at now: Date) -> String {
        Dotted(
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : String(localized: "待回复"),
            PiClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

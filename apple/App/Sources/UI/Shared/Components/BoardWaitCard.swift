import CueStore
import SwiftUI

/// 等你列的一张卡（`TaskBoard.Held`）：一个在等你的会话，与看板别的卡同一种（`BoardCardLayout`，一样高，一个记号加名字）。
/// - 记号说状态：会话在问你是赭黄问号（`PiStateGlyph(.asking)`），待回复是墨点（`PiStateGlyph(.awaitsReply)`，各处待回复同一个，赭黄只给拍板）。
/// - 名字同别的列：绑着的任务名，没绑任务的会话名，换列不换名字，折几行同别的卡（`BoardCardMetrics.title`）；看全部项目时前面是项目小图形。
///   问什么在 Mac 的悬停提示里（项目、问句或"待回复"、等了多久）与点进去看。
/// 点卡进那个会话。长按（Mac 右键）是这件事的菜单，同别的列：任务的（`CardActions`，第一项"打开任务"），没绑任务的会话的（`SessionActions`）。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    var body: some View {
        #if os(macOS)
        // 悬停提示里等了多久跟着走：到下一次换字的时刻（`PiClock.Waited`）才重画这张卡
        Moments(next: PiClock.Waited(since: held.session.stateSince).discreteInput(after:)) { now in card.help(tip(at: now)) }
        #else
        card
        #endif
    }

    private var card: some View {
        BoardLink(to: held.session) {
            BoardCardLayout(advancing: false, pulse: leftPulse) {
                PiStateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
                    .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                if held.item?.task.isPinned == true { BoardPin() }
                Text(held.title).foregroundStyle(palette.ink)
            }
            .boardCard(.waiting)
        }
        .contextMenu { menu }
        .accessibilityLabel(Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复")).spoken)
        .accessibilityActions { menu }
        .boardDim(project: held.project)
    }

    @ViewBuilder private var menu: some View {
        if let item = held.item {
            #if os(macOS)
            CardActions(card: item.task, leaf: item.steps == nil, opens: true, session: held.session)
            #else
            CardActions(card: item.task, opens: true, session: held.session)
            #endif
        } else {
            SessionActions(session: held.session)
        }
    }

    /// 刚从推进中飞来时起飞那一下还带着的那条线（`BoardCardLayout`）：任务的或会话的此刻那条。
    private var leftPulse: BoardPulse {
        guard arrival?.from == .advancing else { return BoardPulse() }
        return workspace.pulse(of: held.item?.agent ?? PiSessionListItem(state: held.session))
    }

    #if os(macOS)
    /// 项目、问句（待回复写"待回复"）、等了多久，一行。
    private func tip(at now: Date) -> String {
        Dotted(
            workspace.catalog?.project(held.project)?.shownName, held.deciding ? held.session.asked.line : String(localized: "待回复"),
            PiClock.Waited(since: held.session.stateSince).format(now)
        ).visible
    }
    #endif
}

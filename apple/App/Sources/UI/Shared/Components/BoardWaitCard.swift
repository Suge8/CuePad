import CueStore
import SwiftUI

/// 等你列的一张卡（`TaskBoard.Held`）：进展页只看不答，与看板别的卡同一种（`BoardCardLayout`，一样高，一个记号加名字）。
/// - 记号说状态：拍板是赭黄问号（`PiStateGlyph(.asking)`），只剩待回复是墨点（`PiStateGlyph(.awaitsReply)`，各处待回复同一个，赭黄只给拍板）。
/// - 名字同别的列：这件事本身（任务名，没绑任务的会话名，不落在任务上的 Cue 提问写它要做的事），换列不换名字，折几行同别的卡（`BoardCardMetrics.title`）；看全部项目时前面是项目小图形。
/// - 一件任务上收了几件时右端写件数。问什么在 Mac 的悬停提示里（项目、问句或"待回复"、等了多久，几件时一件一行）与点进去看。
/// 点卡去最早的那件（`TaskBoard.Held.destination`）：Cue 的提问去 Cue 页、拍板卡露的就是这一问，会话在问的与待回复进会话。
/// 长按（Mac 右键）是这件事的菜单，同别的列：任务的（`CardActions`，第一项"打开任务"），没绑任务的会话的（`SessionActions`）；Cue 的一般提问没有。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.boardArrival) private var arrival
    @Environment(\.palette) private var palette

    var body: some View {
        #if os(macOS)
        // 悬停提示里等了多久跟着走：到下一次换字的时刻（`PiClock.Waited`）才重画这张卡
        Moments(next: nextTip) { now in card.help(tip(at: now)) }
        #else
        card
        #endif
    }

    private var card: some View {
        BoardLink(to: held.destination) {
            BoardCardLayout(advancing: false, pulse: leftPulse) {
                mark.frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                if held.item?.task.isPinned == true { BoardPin() }
                Text(held.title).foregroundStyle(palette.ink)
            } trailing: {
                if held.count > 1 {
                    Text("\(held.count) 件").font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink2).fixedSize()
                }
            }
            .boardCard(.waiting)
        }
        .contextMenu { menu }
        .accessibilityLabel(Dotted(held.title, held.deciding ? String(localized: "等你拍板") : String(localized: "待回复"), held.count > 1 ? String(localized: "\(held.count) 件") : nil).spoken)
        .accessibilityActions { menu }
        .boardDim(project: held.project)
    }

    @ViewBuilder private var menu: some View {
        if let item = held.item {
            let session = item.agent?.state
            #if os(macOS)
            CardActions(card: item.task, leaf: item.steps == nil, opens: true, session: session)
            #else
            CardActions(card: item.task, opens: true, session: session)
            #endif
        } else if case .session(let session) = held.destination {
            SessionActions(session: session)
        }
    }

    /// 刚从推进中飞来时起飞那一下还带着的那条线（`BoardCardLayout`）：任务的或会话的此刻那条。
    private var leftPulse: BoardPulse {
        guard arrival?.from == .advancing else { return BoardPulse() }
        if let item = held.item { return workspace.pulse(of: item.agent) }
        return workspace.pulse(of: held.replies.first.map { PiSessionListItem(state: $0.session) })
    }

    private var mark: some View {
        PiStateGlyph(status: held.deciding ? .asking : .awaitsReply).font(.system(size: TaskMetrics.ring))
    }

    #if os(macOS)
    /// 一件：项目、问句（待回复写"待回复"）、等了多久，一行；几件时项目一行，下面一件一行。
    private func tip(at now: Date) -> String {
        let project = workspace.catalog?.project(held.project)?.shownName
        let lines = held.waits.map { Dotted($0.asked.line, PiClock.Waited(since: $0.since).format(now)).visible }
            + held.replies.map { Dotted(String(localized: "待回复"), PiClock.Waited(since: $0.session.stateSince).format(now)).visible }
        if lines.count == 1 { return Dotted(project, lines[0]).visible }
        return ([project].compactMap(\.self) + lines).joined(separator: "\n")
    }

    /// 提示里最早要换字的那一刻。
    private func nextTip(after now: Date) -> Date? {
        (held.waits.map(\.since) + held.replies.map(\.session.stateSince)).compactMap { PiClock.Waited(since: $0).discreteInput(after: now) }.min()
    }
    #endif
}

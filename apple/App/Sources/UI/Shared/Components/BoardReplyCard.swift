import CueStore
import SwiftUI

/// 等你列里待回复的一件（`TaskBoard.Reply`）：比拍板轻，同看板别的卡的语法（`BoardCardLayout`）——开头一颗墨色圆点（同 Cue 页的待回复提示，赭黄只给拍板），
/// 看全部项目时是项目小图形，标题是绑着的任务名、没绑写会话名；右端"待回复"与等了多久。不给回答框：待回复要进会话说，点卡就进会话。
struct BoardReplyCard: View {
    let reply: TaskBoard.Reply
    let project: Project?
    @Environment(\.palette) private var palette

    var body: some View {
        let title = reply.item?.task.title ?? reply.session.title
        BoardLink(to: .session(reply.session), card: true) {
            BoardCardLayout(advancing: false) {
                Circle().fill(palette.ink).frame(width: Self.dot, height: Self.dot)
                    .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                Text(title).boardTitle(advancing: false).foregroundStyle(palette.ink)
            } trailing: {
                HStack(spacing: 6) {
                    Text("待回复").foregroundStyle(palette.ink2).fontWeight(.semibold)
                    LiveText(style: PiClock.Elapsed(since: reply.session.stateSince)).monospacedDigit().foregroundStyle(palette.ink3)
                }
                .font(TaskMetrics.caption)
                .fixedSize()
            }
            .boardCard(advancing: false)
        }
        .accessibilityLabel("\(title)，待回复")
        .boardDim(project: reply.project)
    }

    private static let dot: CGFloat = 7
}

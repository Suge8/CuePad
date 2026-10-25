import CueStore
import SwiftUI

/// 等你列里拍板的一件（待回复是 `BoardReplyCard`）：进展页只看不答，与看板别的卡同一种（`BoardCardLayout`，一样高，一个记号加一行字）——
/// 开头赭黄问号（`PiStateGlyph(.asking)`），看全部项目时是项目小图形，标题是短事由（`TaskBoard.Wait.brief`：Cue 的提问是它要做的那件事，会话在问的是会话名），可折两行。
/// 点卡去答：Cue 的提问去 Cue 页、这一问排到拍板卡最前（`Workspace.askOnCuePage`），会话在问的进会话。Mac 上悬停是项目、完整问句与等了多久。
struct BoardWaitCard: View {
    let wait: TaskBoard.Wait
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        BoardLink(to: destination) {
            BoardCardLayout(advancing: false) {
                PiStateGlyph(status: .asking).font(.system(size: TaskMetrics.ring))
                    .frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                Text(wait.brief).boardTitle(advancing: false, wraps: true).foregroundStyle(palette.ink)
            }
            .boardCard(advancing: false)
        }
        #if os(macOS)
        .help(Dotted(workspace.catalog?.project(wait.shownProject)?.name, wait.asked.line, PiClock.Waited(since: wait.since).format(.now)).visible)
        #endif
        .accessibilityLabel("\(wait.asked.line)，等你拍板")
        .boardDim(project: wait.project)
    }

    private var destination: BoardDestination {
        switch wait.wait {
        case .message(let message, _): .question(message.id)
        case .session(let session, _): .session(session)
        }
    }
}

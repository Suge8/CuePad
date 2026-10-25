import CueStore
import SwiftUI

/// 等你列的一张卡（`TaskBoard.Held`）：进展页只看不答，与看板别的卡同一种（`BoardCardLayout`，一样高，一个记号加名字）。
/// - 记号说状态：拍板是赭黄问号（`PiStateGlyph(.asking)`），只剩待回复是墨色圆点（同 Cue 页的待回复提示，赭黄只给拍板）。
/// - 名字同别的列：这件事本身（任务名，没绑任务的会话名，不落在任务上的 Cue 提问写它要做的事），换列不换名字，可折两行；看全部项目时前面是项目小图形。
/// - 一件任务上收了几件时右端写件数。问什么在 Mac 的悬停提示里（项目、问句或"待回复"、等了多久，几件时一件一行）与点进去看。
/// 点卡去最早的那件：Cue 的提问去 Cue 页、这一问排到拍板卡最前（`Workspace.askOnCuePage`），会话在问的与待回复进会话。
struct BoardWaitCard: View {
    let held: TaskBoard.Held
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        BoardLink(to: destination) {
            BoardCardLayout(advancing: false) {
                mark.frame(width: TaskMetrics.cardLead, height: TaskMetrics.cardLead)
                if let project { BoardProjectGlyph(project: project) }
                Text(held.title).boardTitle(advancing: false, wraps: true).foregroundStyle(palette.ink)
            } trailing: {
                if held.count > 1 {
                    Text("\(held.count) 件").font(TaskMetrics.caption).monospacedDigit().foregroundStyle(palette.ink2).fixedSize()
                }
            }
            .boardCard(advancing: false)
        }
        #if os(macOS)
        .help(tip)
        #endif
        .accessibilityLabel(Dotted(held.title, held.deciding ? "等你拍板" : "待回复", held.count > 1 ? "\(held.count) 件" : nil).spoken)
        .boardDim(project: held.project)
    }

    @ViewBuilder private var mark: some View {
        if held.deciding {
            PiStateGlyph(status: .asking).font(.system(size: TaskMetrics.ring))
        } else {
            Circle().fill(palette.ink).frame(width: Self.dot, height: Self.dot)
        }
    }

    private var destination: BoardDestination {
        if let wait = held.waits.first {
            switch wait.wait {
            case .message(let message, _): return .question(message.id)
            case .session(let session, _): return .session(session)
            }
        }
        return .session(held.replies[0].session)
    }

    /// 一件：项目、问句（待回复写"待回复"）、等了多久，一行；几件时项目一行，下面一件一行。
    private var tip: String {
        let project = workspace.catalog?.project(held.project)?.name
        let lines = held.waits.map { Dotted($0.asked.line, PiClock.Waited(since: $0.since).format(.now)).visible }
            + held.replies.map { Dotted("待回复", PiClock.Waited(since: $0.session.stateSince).format(.now)).visible }
        if lines.count == 1 { return Dotted(project, lines[0]).visible }
        return ([project].compactMap(\.self) + lines).joined(separator: "\n")
    }

    private static let dot: CGFloat = 7
}

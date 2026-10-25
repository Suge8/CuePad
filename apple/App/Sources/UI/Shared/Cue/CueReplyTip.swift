import CueStore
import SwiftUI

/// 待回复（WORDS.md）：Cue 页等你卡上方的一条提示，说 Cue 留给你回、此刻歇着的会话（`CueThread.replies`，等得最久的在前）。
/// 它们不是拍板，不进等你卡：一颗与输入框同族的玻璃胶囊（`ControlButtonStyle.glass`，比输入框矮），左边一颗墨色圆点（赭黄只给拍板）。
/// 一个写"<会话名> 待回复"，点了进那个会话；几个写"<N> 个会话待回复"，点了去进展页的会话段（`Workspace.showReplies`，待回复排最前）。
/// 没有待回复时不占位（`CuePage`）。
struct CueReplyTip: View {
    let replies: [PiSessionState]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ReplyDot()
                if let only {
                    Text(Self.name(only)).foregroundStyle(palette.ink).lineLimit(1)
                    Text("待回复").foregroundStyle(palette.ink2).fixedSize()
                } else {
                    Text("\(replies.count) 个会话待回复").foregroundStyle(palette.ink).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(.forward).font(.system(size: 10, weight: .bold)).foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ControlButtonStyle(kind: .glass))
        .accessibilityLabel(only.map { "\(Self.name($0)) 待回复" } ?? "\(replies.count) 个会话待回复")
        .padding(.bottom, Self.below)
    }

    private var only: PiSessionState? { replies.count == 1 ? replies.first : nil }

    private static func name(_ session: PiSessionState) -> String { session.title.isEmpty ? "会话" : session.title }

    private func open() {
        if let only { workspace.openSession(only.id, sessionID: only.sessionID) } else { workspace.showReplies() }
    }

    /// 与下面等你卡（或输入框）之间，同等你卡与输入框之间。
    private static let below = ComposerMetrics.stackGap
}

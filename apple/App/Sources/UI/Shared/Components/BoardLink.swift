import CueStore
import SwiftUI

/// 看板上点了进会话的一张卡（推进中的会话卡、等你列的待回复）：整张是按钮（`PressStyle(.card)`，悬停亮一档）。
struct BoardLink<Label: View>: View {
    let session: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.openSession(session.id, sessionID: session.sessionID) } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint("打开会话")
    }
}

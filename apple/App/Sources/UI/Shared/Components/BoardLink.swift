import CueStore
import SwiftUI

/// 看板上点了进会话的一张卡（推进中的会话卡、等你列的卡）：整张是按钮（`PressStyle(.card)`，悬停亮一档）。
struct BoardLink<Label: View>: View {
    let to: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.openSession(to.id, sessionID: to.sessionID) } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(Text("打开会话"))
    }
}

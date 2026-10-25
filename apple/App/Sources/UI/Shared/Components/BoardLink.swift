import CueStore
import SwiftUI

/// 看板上点了去别处的一张卡（推进中的会话卡、等你列的拍板与待回复）：整张是按钮（`PressStyle(.card)`，悬停亮一档），去处见 `Workspace.open(_:)`。
struct BoardLink<Label: View>: View {
    let to: TaskBoard.Destination
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.open(to) } label: {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityHint(hint)
    }

    private var hint: String {
        switch to {
        case .session: "打开会话"
        case .question: "去 Cue 页回答"
        }
    }
}

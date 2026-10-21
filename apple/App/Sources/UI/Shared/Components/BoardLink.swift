import CueStore
import SwiftUI

/// 看板上点了去哪：进会话，或去 Cue 页那条提问（`Workspace.cueAsking`）。
enum BoardDestination {
    case session(PiSessionState)
    case question(UUID)
}

/// 看板上点了去别处的一块：等你卡的抬头是一行（`RowStyle`，悬停与按下铺淡底），推进中的会话卡（`card`）是一张卡（`PressStyle(.card)`，悬停亮一档）。
struct BoardLink<Label: View>: View {
    let to: BoardDestination
    var card = false
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let button = Button(action: open) {
            label.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
        }
        Group {
            if card { button.buttonStyle(PressStyle(.card)) } else { button.buttonStyle(.row) }
        }
        .accessibilityHint(hint)
    }

    private var hint: String {
        switch to {
        case .session: "打开会话"
        case .question: "去 Cue 页回答"
        }
    }

    private func open() {
        switch to {
        case .session(let session): workspace.openSession(session.id, sessionID: session.sessionID)
        case .question(let id):
            workspace.cueAsking = id
            workspace.show(.cue)
        }
    }
}

import CueStore
import SwiftUI

/// 看板上点了去哪：进会话，或去 Cue 页答那一问（`Workspace.askOnCuePage`）。
enum BoardDestination {
    case session(PiSessionState)
    case question(UUID)
}

/// 看板上点了去别处的一张卡（推进中的会话卡、等你列的拍板与待回复）：整张是按钮（`PressStyle(.card)`，悬停亮一档）。
struct BoardLink<Label: View>: View {
    let to: BoardDestination
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button(action: open) {
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

    private func open() {
        switch to {
        case .session(let session): workspace.openSession(session.id, sessionID: session.sessionID)
        case .question(let id): workspace.askOnCuePage(id)
        }
    }
}

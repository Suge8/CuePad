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
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

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
        case .session(let session):
            #if os(macOS)
            workspace.show(.session(session.sessionID))
            #else
            navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
            #endif
        case .question(let id):
            workspace.cueAsking = id
            #if os(macOS)
            workspace.show(.cue)
            #else
            navigation.show(.cue)
            #endif
        }
    }
}

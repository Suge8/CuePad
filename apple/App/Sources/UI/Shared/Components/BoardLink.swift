import CueStore
import SwiftUI

/// 看板上点了去哪：进会话，或去 Cue 页那条提问（`Workspace.cueAsking`）。
enum BoardDestination {
    case session(PiSessionState)
    case question(UUID)
}

/// 看板上点了去别处的一块（推进中的会话行、等你卡的抬头）。Mac 上是悬停铺淡底的一行（`RowStyle`），手机按下变淡（同任务行）。
struct BoardLink<Label: View>: View {
    let to: BoardDestination
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
        .accessibilityHint(hint)
        #if os(macOS)
        button.buttonStyle(RowStyle(hovers: true))
        #else
        button.buttonStyle(PressStyle(.card))
        #endif
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

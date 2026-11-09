import CueStore
import SwiftUI

struct BoardLink<Label: View>: View {
    let to: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 不在这里挂拖动：卡的拖动由看板挂在外面（`boardDraggable`，宽屏上同时带着会话、能拖进并排的会话格）。里层的拖动先认手势，
        // 只带会话的那份落不进看板的列。
        control
            .accessibilityHint(Text("打开会话"))
    }

    @ViewBuilder private var control: some View {
        #if os(macOS)
        Button { open(NSApp.currentEvent?.modifierFlags.contains(.command) == true) } label: { label }
            .buttonStyle(PressStyle(.card))
        #else
        if workspace.layout == .wide {
            label.contentShape(.rect)
                .gesture(SessionTap(action: open))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(false) }
        } else {
            Button { open(false) } label: { label }.buttonStyle(PressStyle(.card))
        }
        #endif
    }

    private func open(_ beside: Bool) {
        workspace.openSession(to.id, sessionID: to.sessionID, in: beside ? .beside : .main)
    }
}

struct OpenSessionBeside: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.layout == .wide {
            Button("在旁边打开") { workspace.openSession(session.id, sessionID: session.sessionID, in: .beside) }
        }
    }
}

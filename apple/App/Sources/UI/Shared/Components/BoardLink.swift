import CueStore
import SwiftUI

/// 看板上点了进会话的一张卡（推进中的会话卡、等你列的卡）：整张是按钮（`PressStyle(.card)`，悬停亮一档）。
struct BoardLink<Label: View>: View {
    let to: PiSessionState
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        control
            .sessionDraggable(to)
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

    private func open(_ leading: Bool) {
        workspace.openSession(to.id, sessionID: to.sessionID, in: leading ? .main : .side)
    }
}

struct OpenSessionLeading: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.layout == .wide {
            Button("在左边打开") { workspace.openSession(session.id, sessionID: session.sessionID, in: .main) }
        }
    }
}

extension View {
    func sessionDraggable(_ session: PiSessionState) -> some View { modifier(SessionDraggable(session: session)) }
}

private struct SessionDraggable: ViewModifier {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        if workspace.layout == .wide { content.draggable(DraggedSession(sessionID: session.sessionID)) } else { content }
    }
}

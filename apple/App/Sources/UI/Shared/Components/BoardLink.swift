import CueStore
import SwiftUI

/// 看板上点了进会话的一张卡（推进中的会话卡、等你列的卡）：整张是按钮（`PressStyle(.card)`，悬停亮一档）。
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

    /// 宽屏开在主区；⌘ 点（iPad 是按住 ⌘ 轻点）的开在右半并排。
    private func open(_ beside: Bool) {
        workspace.openSession(to.id, sessionID: to.sessionID, in: beside ? .beside : .main)
    }
}

/// 右键菜单里的"在旁边打开"（宽屏）：开在主区右半、与此刻的会话并排（同 ⌘ 点）。
struct OpenSessionBeside: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.layout == .wide {
            Button("在旁边打开") { workspace.openSession(session.id, sessionID: session.sessionID, in: .beside) }
        }
    }
}

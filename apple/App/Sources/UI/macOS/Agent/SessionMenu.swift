#if os(macOS)
import CueStore
import SwiftUI

/// Mac 会话行的右键菜单（Agent 整页）：标为未读、重命名、跳到所在终端（本机桥上开在终端里的）、
/// 结束会话（`end` 非空时；调用处先确认，确认后发给它所在的 Mac，对话留着）。桥上的那个会话只在这里读（`pi.session(sessionID:)`）：
/// 列表读全部会话的话，任一会话一变整列重算。
struct SessionMenu: View {
    let session: PiSessionState
    let rename: () -> Void
    let end: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        MarkUnreadButton(session: session)
        if MacDelivery.canRename(session) {
            Button("重命名…", icon: .rename, action: rename)
        }
        if let bridge = services.pi.session(sessionID: session.sessionID), bridge.canJump {
            Button("跳到所在终端", icon: .terminal) { workspace.jumpToTerminal(bridge.id) }
        }
        if let end {
            Button("结束会话", icon: .endSession, role: .destructive, action: end)
        }
    }
}
#endif

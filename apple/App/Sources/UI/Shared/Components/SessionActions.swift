import CueStore
import SwiftUI

/// 一个会话的菜单项（长按 / Mac 右键，或会话页的"⋯"）：会话出现的每一处共用这一份，有哪几项、什么顺序只在这里——
/// 标为未读、去它在等的那一处（`HandoffButton`）、置顶（绑着任务时：会话自己没有置顶，置的是那件任务，`SessionTask`）、重命名、
/// 跳到所在终端（Mac 本机桥上开在终端里的）、结束会话。挂在进展页会话段的行、看板推进中的会话卡、两端会话页的"⋯"上；
/// 手机会话行的左滑露出结束与重命名（`swipes`）。重命名与结束要再确认，交给窗口上那一格（`Workspace.sessionAsk`）。
struct SessionActions: View {
    let session: PiSessionState
    var task: SessionTask?
    /// 结束请求在路上（`DeliveryRequest.shownEnd`）：结束会话置灰。
    var ending = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        MarkUnreadButton(session: session)
        HandoffButton(session: session)
        if let task {
            let item: CardMenu.Item = task.isPinned ? .unpin : .pin
            Button(item.title, icon: item.icon) { workspace.setPinned(task.id, !task.isPinned) }
        }
        if let rename = Self.rename(session, in: workspace) { RowActionButtons(actions: [rename]) }
        #if os(macOS)
        if let bridge = workspace.services.pi.session(sessionID: session.sessionID), bridge.canJump {
            Button("跳到所在终端", icon: .terminal) { workspace.jumpToTerminal(bridge.id) }
        }
        #endif
        if let end = Self.end(session, ending: ending, in: workspace) { RowActionButtons(actions: [end]) }
    }

    /// 重命名：做得到的（`MacDelivery.canRename`，已结束的也能改）；手机上够不着 Mac 时置灰。
    static func rename(_ session: PiSessionState, in workspace: Workspace) -> RowAction? {
        guard MacDelivery.canRename(session) else { return nil }
        #if os(macOS)
        return RowAction("重命名…", icon: .rename) { workspace.sessionAsk = .rename(session) }
        #else
        return RowAction("重命名", icon: .rename, tone: .quiet, enabled: workspace.services.reachesPiHost) { workspace.sessionAsk = .rename(session) }
        #endif
    }

    /// 结束会话：还在线、做得到的（`PiSessionState.canEnd`）。结束不是删除（对话留着，再说话就恢复），用墨色，确认框里再说清后果。
    static func end(_ session: PiSessionState, ending: Bool, in workspace: Workspace) -> RowAction? {
        guard session.canEnd else { return nil }
        return RowAction("结束会话", icon: .endSession, enabled: !ending) { workspace.sessionAsk = .end(session) }
    }

    /// 手机会话行慢慢左滑露出的：结束在最外侧，其次重命名。
    static func swipes(_ session: PiSessionState, ending: Bool, in workspace: Workspace) -> RowSwipes {
        RowSwipes(trailing: [end(session, ending: ending, in: workspace), rename(session, in: workspace)].compactMap { $0 })
    }
}

/// 会话菜单里的"标为未读"：做完一轮停着、你看过了的会话才有（`PiUnread.canMarkUnread`）；
/// 标了之后它回到"有新回复"（石绿铃铛），直到你再打开它。
struct MarkUnreadButton: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        if services.settings.canMarkUnread(session) {
            Button("标为未读", icon: .markUnread) { services.settings.markUnread(session) }
        }
    }
}

/// 要你再确认一下的会话操作（`SessionActions` 置起）：改名的表单、结束的确认。窗口上只有一格弹它（`sessionAsks`）。
enum SessionAsk: Identifiable, Equatable {
    case rename(PiSessionState)
    case end(PiSessionState)

    var id: String {
        switch self {
        case .rename(let session): "rename/\(session.id)"
        case .end(let session): "end/\(session.id)"
        }
    }
}

extension Workspace {
    /// 置顶、取消置顶一条卡（灵感与顶层任务；会话的置顶也落在它绑着的任务上）。
    func setPinned(_ card: UUID, _ pinned: Bool) {
        perform { try await $0.updateCard(card) { $0.isPinned = pinned } }
    }
}

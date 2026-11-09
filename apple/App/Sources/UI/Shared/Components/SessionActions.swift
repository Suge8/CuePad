import CueStore
import SwiftUI

/// 会话出现的每一处共用这一份，有哪几项、什么顺序只在这里。看板上不归没做完的事的会话卡（`board`）与任务同一组操作：多一项完成（在做或在等你时先问，`Workspace.finish`），置顶与重命名都落在当场给它建的那件任务上（`Workspace+Adopt`）。重命名与结束要再确认，交给窗口上那一格（`Workspace.sessionAsk`）。
struct SessionActions: View {
    let session: PiSessionState
    var task: SessionTask?
    var board: PiSessionListItem?
    var ending = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        MarkUnreadButton(session: session)
        HandoffButton(session: session)
        if let board {
            let session = session
            Button(CardMenu.Item.complete.title, icon: CardMenu.Item.complete.icon) { workspace.attempt { try await workspace.finish(board) } }
            Button(CardMenu.Item.pin.title, icon: CardMenu.Item.pin.icon) { workspace.attempt { try await workspace.pin(session) } }
        } else if let task {
            let item: CardMenu.Item = task.isPinned ? .unpin : .pin
            Button(item.title, icon: item.icon) { workspace.setPinned(task.id, !task.isPinned) }
        }
        if let rename = Self.rename(session, task: task, adopts: board != nil, in: workspace) { RowActionButtons(actions: [rename]) }
        #if os(macOS)
        if let bridge = workspace.services.pi.session(sessionID: session.sessionID), bridge.canJump {
            Button("跳到所在终端", icon: .terminal) { workspace.jumpToTerminal(bridge.id) }
        }
        #endif
        if let end = Self.end(session, ending: ending, in: workspace) { RowActionButtons(actions: [end]) }
        #if os(iOS)
        Section { RemoteMacActions(host: session.hostID) }
        #endif
    }

    static func rename(_ session: PiSessionState, task: SessionTask? = nil, adopts: Bool = false, in workspace: Workspace) -> RowAction? {
        guard MacDelivery.canRename(session) else { return nil }
        let ask = SessionAsk.rename(session, shown: task?.title.nonEmpty ?? session.title, adopts: adopts)
        #if os(macOS)
        return RowAction("重命名…", icon: .rename) { workspace.sessionAsk = ask }
        #else
        return RowAction("重命名", icon: .rename, tone: .quiet, enabled: workspace.services.reachesPiHost) { workspace.sessionAsk = ask }
        #endif
    }

    /// 结束不是删除（对话留着，再说话就恢复），用墨色，确认框里再说清后果。
    static func end(_ session: PiSessionState, ending: Bool, recovering: Bool = false, in workspace: Workspace) -> RowAction? {
        guard session.canEnd || recovering else { return nil }
        return RowAction("结束会话", icon: .endSession, enabled: !ending) { workspace.sessionAsk = .end(session) }
    }

    static func swipes(_ session: PiSessionState, task: SessionTask?, ending: Bool, in workspace: Workspace) -> RowSwipes {
        RowSwipes(trailing: [end(session, ending: ending, in: workspace), rename(session, task: task, in: workspace)].compactMap { $0 })
    }
}

struct MarkUnreadButton: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        if services.settings.canMarkUnread(session) {
            Button("标为未读", icon: .markUnread) { services.settings.markUnread(session) }
        }
    }
}

enum SessionAsk: Identifiable, Equatable {
    case rename(PiSessionState, shown: String, adopts: Bool)
    case end(PiSessionState)
    case complete(PiSessionState)

    var id: String {
        switch self {
        case .rename(let session, _, _): "rename/\(session.id)"
        case .end(let session): "end/\(session.id)"
        case .complete(let session): "complete/\(session.id)"
        }
    }
}

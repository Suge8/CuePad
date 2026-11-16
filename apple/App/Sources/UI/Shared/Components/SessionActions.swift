import CueStore
import SwiftUI

/// 会话的菜单，出现的每一处（会话条、看板、会话列表、会话页栏头）都是这一份，有哪几项、什么顺序只在这里。三组：去哪看（在旁边打开、它在等的那件）、
/// 整理（完成、置顶、重命名、标为未读）、结束会话。完成、置顶、重命名与任务是同一组操作：归着任务的落在那件任务上，没归着的活会话当场给它建一件（`Workspace+Adopt`）。
/// 重命名与结束要再确认，交给窗口上那一格（`Workspace.sessionAsk`）。
struct SessionActions: View {
    let session: SessionState
    var task: SessionTask?
    var ending = false
    /// 会话页栏头的完成按任务列在它自己那一组（`SessionMenuItems`），这里不再给。
    var completes = true
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            Section {
                OpenSessionBeside(session: session)
                HandoffButton(session: session)
            }
            arrange
            Section {
                if let end = Self.end(session, ending: ending, in: workspace) { RowActionButtons(actions: [end]) }
            }
            #if os(iOS)
            Section { RemoteMacActions(host: session.hostID) }
            #endif
        }
        .menuIcons()
    }

    private var arrange: some View {
        Section {
            if completes, task != nil || session.canEnd {
                let agent = SessionListItem(state: session, task: task)
                Button(CardMenu.Item.complete.title, icon: CardMenu.Item.complete.icon) { workspace.attempt { try await workspace.finish(agent) } }
            }
            if let task {
                let item: CardMenu.Item = task.isPinned ? .unpin : .pin
                Button(item.title, icon: item.icon) { workspace.setPinned(task.id, !task.isPinned) }
            } else if session.canEnd {
                let session = session
                Button(CardMenu.Item.pin.title, icon: CardMenu.Item.pin.icon) { workspace.attempt { try await workspace.pin(session) } }
            }
            RowActionButtons(actions: [Self.rename(session, task: task, in: workspace)])
            MarkUnreadButton(session: session)
        }
    }

    static func rename(_ session: SessionState, task: SessionTask? = nil, in workspace: Workspace) -> RowAction {
        let ask = SessionAsk.rename(session, shown: task?.title.nonEmpty ?? session.title, adopts: task == nil && session.canEnd)
        #if os(macOS)
        return RowAction("重命名…", icon: .rename) { workspace.sessionAsk = ask }
        #else
        return RowAction("重命名", icon: .rename, tone: .quiet, enabled: workspace.services.syncing.reachesHost) { workspace.sessionAsk = ask }
        #endif
    }

    /// 结束不是删除（对话留着，再说话就恢复），用墨色，确认框里再说清后果。
    static func end(_ session: SessionState, ending: Bool, recovering: Bool = false, in workspace: Workspace) -> RowAction? {
        guard session.canEnd || recovering else { return nil }
        return RowAction("结束会话", icon: .endSession, enabled: !ending) { workspace.sessionAsk = .end(session) }
    }

    static func swipes(_ session: SessionState, task: SessionTask?, ending: Bool, in workspace: Workspace) -> RowSwipes {
        RowSwipes(trailing: [end(session, ending: ending, in: workspace), rename(session, task: task, in: workspace)].compactMap { $0 })
    }
}

struct MarkUnreadButton: View {
    let session: SessionState
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if session.canMarkUnread(services.liveSessions.marks[session.sessionID], at: .now) {
            Button("标为未读", icon: .markUnread) { [store = services.store, id = session.sessionID] in workspace.attempt { try await store.mark(.sessionUnread(id)) } }
        }
    }
}

enum SessionAsk {
    case rename(SessionState, shown: String, adopts: Bool)
    case end(SessionState)
    /// 完成前先问（`Workspace.confirmComplete`），答应了跑 `then`。`claimer` 是挨着它弹出的那个视图，nil 时窗口居中出。
    case complete(CompletionAsk, claimer: UUID?, then: @MainActor (Workspace) async throws -> Void)
}

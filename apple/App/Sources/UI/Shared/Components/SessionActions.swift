import CueStore
import SwiftUI

struct SessionActions: View {
    let session: SessionState
    var task: SessionTask?
    var ending = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            Section {
                OpenSessionBeside(session: session)
                HandoffButton(session: session)
            }
            Section {
                if let task {
                    let item: CardMenu.Item = task.isPinned ? .unpin : .pin
                    Button(item.title, icon: item.icon) { workspace.setPinned(task.id, !task.isPinned) }
                } else if session.canEnd {
                    let session = session
                    Button(CardMenu.Item.pin.title, icon: CardMenu.Item.pin.icon) { workspace.attempt { try await workspace.pin(session) } }
                }
                RowActionButtons(actions: [Self.rename(session, task: task, in: workspace)])
                MarkUnreadButton(session: session)
                OpenLivePreviewButton(session: session)
            }
            Section {
                if let complete = Self.complete(session, task: task, in: workspace) { RowActionButtons(actions: [complete]) }
                if let sleep = Self.sleep(session, task: task, ending: ending, in: workspace) { RowActionButtons(actions: [sleep]) }
            }
            #if os(iOS)
            Section { RemoteMacActions(host: session.hostID) }
            #endif
        }
        .menuIcons()
    }

    private static func owned(_ task: SessionTask?) -> Bool { task?.isDone == false }

    static func rename(_ session: SessionState, task: SessionTask? = nil, in workspace: Workspace) -> RowAction {
        let ask = SessionAsk.rename(session, shown: task?.title.nonEmpty ?? session.title, adopts: !owned(task) && session.canEnd)
        #if os(macOS)
        return RowAction("重命名…", icon: .rename) { workspace.sessionAsk = ask }
        #else
        return RowAction("重命名", icon: .rename, tone: .quiet, enabled: workspace.services.syncing.reachesHost) { workspace.sessionAsk = ask }
        #endif
    }

    static func complete(_ session: SessionState, task: SessionTask?, in workspace: Workspace) -> RowAction? {
        guard session.canEnd || owned(task) else { return nil }
        let agent = SessionListItem(state: session, task: task)
        return RowAction(CardMenu.Item.complete.title, icon: CardMenu.Item.complete.icon) { workspace.attempt { try await workspace.finish(agent) } }
    }

    static func sleep(_ session: SessionState, task: SessionTask? = nil, ending: Bool, recovering: Bool = false, in workspace: Workspace) -> RowAction? {
        guard recovering || session.canEnd && owned(task) else { return nil }
        return RowAction("休眠", icon: .ended, enabled: !ending) { workspace.sleep(session) }
    }

    static func swipes(_ session: SessionState, task: SessionTask?, ending: Bool, in workspace: Workspace) -> RowSwipes {
        let close = sleep(session, task: task, ending: ending, in: workspace) ?? complete(session, task: task, in: workspace)
        return RowSwipes(trailing: [close, rename(session, task: task, in: workspace)].compactMap { $0 })
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
    case complete(CompletionAsk, claimer: UUID?, then: @MainActor (Workspace) async throws -> Void)
}

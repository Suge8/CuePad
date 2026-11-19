import CueStore
import SwiftUI

/// 会话的菜单，出现的每一处（会话条、看板、会话列表、会话页栏头）都是这一份，有哪几项、什么顺序只在这里。三组：去哪看（并排打开、它在等的那件）、
/// 整理（置顶、重命名、标为未读）、收尾。收尾只有一个词：完成——这件事用完了，会话跟着休眠（`Workspace.complete`）。
/// 休眠只在它归着没做完的任务时另给一项：事还没完，先让 Agent 歇着。没归着任务的不给，完成就是它。
/// 置顶、重命名、完成与任务是同一组操作：归着任务的落在那件任务上，没归着的活会话当场给它建一件（`Workspace+Adopt`）；
/// 只归着做完的旧任务的活会话，完成与重命名照没归着的走（同看板上它那张会话卡）。重命名要填名字、在忙的休眠要再确认，交给窗口上那一格（`Workspace.sessionAsk`）。
struct SessionActions: View {
    let session: SessionState
    var task: SessionTask?
    var ending = false
    /// 会话页栏头：有没做完的任务时，完成按任务列在它自己那一组（`SessionMenuItems`），这里不再给。
    var completes = true
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            Section {
                OpenSessionBeside(session: session)
                HandoffButton(session: session)
                #if os(macOS)
                // 有页面可看时栏头有那颗钮，这里不再给第二个入口
                if workspace.livesHere(session), workspace.liveButton(session.id) == nil {
                    Button("打开活预览", icon: .livePreview) { workspace.openLivePreview(session) }
                }
                #endif
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
            }
            Section {
                if completes, let complete = Self.complete(session, task: task, in: workspace) { RowActionButtons(actions: [complete]) }
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

    /// 休眠不是删除（对话留着，再说话就醒），用墨色；在忙才问（`Workspace.sleep`）。归着没做完的任务才给；`recovering`：上一次休眠没成或没确认，会话页就地再来一次。
    static func sleep(_ session: SessionState, task: SessionTask? = nil, ending: Bool, recovering: Bool = false, in workspace: Workspace) -> RowAction? {
        guard recovering || session.canEnd && owned(task) else { return nil }
        return RowAction("休眠", icon: .ended, enabled: !ending) { workspace.sleep(session) }
    }

    /// 轻扫与菜单同一个收尾：没归着任务的是完成，归着的是休眠。
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
    /// 完成前先问（`Workspace.confirmComplete`），答应了跑 `then`。`claimer` 是挨着它弹出的那个视图，nil 时窗口居中出。
    case complete(CompletionAsk, claimer: UUID?, then: @MainActor (Workspace) async throws -> Void)
}

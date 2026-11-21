import CueStore
import SwiftUI

/// 会话页栏头的菜单：三端同一份（宽屏是栏头的右键菜单，手机点页头的标题）。只放这个会话自己的事：收尾（完成、休眠）、改名、归到哪件任务、
/// 去它在等的那件；置顶、标为未读、并排打开是排列表的事，在会话条、看板与列表的菜单里（`SessionActions`），这里不抄一份。
struct SessionMenuItems: View {
    let session: SessionState
    let place: String?
    let task: SessionTaskLink?
    let pin: SessionTask?
    let ending: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let open = task?.tasks.filter { $0.task.status != .done } ?? []
        Group {
            if let place { Section { } header: { Text(place) } }
            Section {
                ForEach(open) { item in
                    Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", icon: .complete) { workspace.completeTask(item.task.id) }
                }
                if open.isEmpty, let complete = SessionActions.complete(session, task: pin, in: workspace) { RowActionButtons(actions: [complete]) }
                if let sleep = SessionActions.sleep(session, task: pin, ending: ending, in: workspace) { RowActionButtons(actions: [sleep]) }
            }
            Section {
                RowActionButtons(actions: [SessionActions.rename(session, task: pin, in: workspace)])
                if let link = task { SessionTaskBindItems(session: session, link: link) }
                HandoffButton(session: session)
                #if os(macOS)
                // 少用的兜底入口；有页面可看时栏头有那颗钮，这里不再给第二个入口
                if workspace.livesHere(session), workspace.liveButton(session.id) == nil {
                    Button("打开活预览", icon: .livePreview) { workspace.openLivePreview(session) }
                }
                #endif
            }
            #if os(iOS)
            Section { RemoteMacActions(host: session.hostID) }
            #endif
        }
        .menuIcons()
    }
}

extension Workspace {
    /// 完成就是做完了：会话绑着的事都做完了就结束它。
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}

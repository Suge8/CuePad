import CueStore
import SwiftUI

/// 会话页栏头的菜单：三端同一份（宽屏是栏头的右键菜单，手机点页头的标题）。
/// 手机上会话只绑着一件没做完的事时，完成是页头右边那颗钮（`SessionPage`），菜单里不再写一遍（`completes` 为假）。
struct SessionMenuItems: View {
    let session: SessionState
    let place: String?
    let task: SessionTaskLink?
    let pin: SessionTask?
    let ending: Bool
    var completes = true
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let open = task?.tasks.filter { $0.task.status != .done } ?? []
        if let place { Section { } header: { Text(place) } }
        if let link = task {
            let open = completes ? open : []
            ForEach(open) { item in
                Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", icon: .complete) { workspace.completeTask(item.task.id) }.menuIcons()
            }
            SessionTaskBindItems(session: session, link: link).menuIcons()
            Divider()
        }
        SessionActions(session: session, task: pin, ending: ending, completes: open.isEmpty)
    }
}

extension Workspace {
    /// 完成就是做完了：会话绑着的事都做完了就结束它。
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}

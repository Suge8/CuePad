import CueStore
import SwiftUI

/// 会话页栏头的菜单：三端同一份（宽屏是栏头的右键菜单，手机是页头的"⋯"）。
struct SessionMenuItems: View {
    let session: SessionState
    let place: String?
    let task: SessionTaskLink?
    let pin: SessionTask?
    let ending: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let place { Section { } header: { Text(place) } }
        if let link = task {
            let open = link.tasks.filter { $0.task.status != .done }
            ForEach(open) { item in
                Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", icon: .complete) { workspace.completeTask(item.task.id) }
            }
            SessionTaskBindItems(session: session, link: link)
            Divider()
        }
        SessionActions(session: session, task: pin, ending: ending)
    }
}

extension Workspace {
    /// 完成就是做完了：会话绑着的事都做完了就结束它。
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}

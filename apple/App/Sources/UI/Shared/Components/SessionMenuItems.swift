import CueStore
import SwiftUI

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
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}

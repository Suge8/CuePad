#if os(macOS)
import CuePi
import CueStore
import SwiftUI

@Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        var delivery: DeliveryRequest?
        var title: String
        var undelivered: String?
        var ending: Bool
        var place: String?
        var pin: SessionTask?
        var showsHeader: Bool
        /// 晚于标题两帧建：建菜单约占点击回合的一半。
        var showsMenu: Bool
        var task: SessionTaskLink?
    }

    private(set) var state: State?
    @ObservationIgnored var reveal: () -> Void = {}

    func set(_ state: State?) {
        if self.state != state { self.state = state }
    }

    func clear(_ sessionID: String) {
        if state?.session.sessionID == sessionID { state = nil }
    }
}

struct PageTitleWidth: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 160, idealWidth: 420, maxWidth: 420)
    }
}

struct SessionMenuItems: View {
    let state: SessionHeader.State
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let session = state.session
        if let place = state.place { Section { } header: { Text(place) } }
        if let link = state.task {
            let open = link.tasks.filter { $0.task.status != .done }
            ForEach(open) { item in
                Button(open.count > 1 ? "完成「\(item.task.title)」" : "完成任务", icon: .complete) { workspace.completeTask(item.task.id) }
            }
            SessionTaskBindItems(session: session, link: link)
            Divider()
        }
        SessionActions(session: session, task: state.pin, ending: state.ending)
    }
}

extension Workspace {
    func showTask(_ task: Card) {
        show(.project(task.projectID))
        open(task)
    }

    /// 完成就是做完了：会话绑着的事都做完了就结束它。
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}
#endif

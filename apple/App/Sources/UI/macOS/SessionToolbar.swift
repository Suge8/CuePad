#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 共用 Workspace 仍持有的旧页头存储；宽屏不再写入，字段删除由导航 Owner 一并收口。
@Observable
final class SessionHeader {
    struct State: Equatable {
        var session: PiSessionState
        /// 发给它的最近一条话（`SessionDigest.delivery`）：顶栏的状态按它写话到哪了。
        var delivery: DeliveryRequest?
        var title: String
        var undelivered: String?
        var ending: Bool
        var place: String?
        /// 绑着的顶层任务（会话菜单的"置顶"置的是它，`SessionActions`）。
        var pin: SessionTask?
        /// 对话在看历史时标题让开。
        var showsHeader: Bool
        /// "⋯"里的菜单项晚于标题两帧建（建菜单约占点击回合的一半）。
        var showsMenu: Bool
        /// 这个会话在做哪几件事；读到前是 nil。
        var task: SessionTaskLink?
    }

    private(set) var state: State?
    @ObservationIgnored var reveal: () -> Void = {}

    func set(_ state: State?) {
        if self.state != state { self.state = state }
    }

    /// 离开的会话页只清自己的：换会话时新页面的值可能已经先到了。
    func clear(_ sessionID: String) {
        if state?.session.sessionID == sessionID { state = nil }
    }
}

struct PageTitleWidth: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 160, idealWidth: 420, maxWidth: 420)
    }
}

/// "⋯"里会话页的那几项：最上面写所在；绑着的每件没完成的事一项"完成"；"绑定到任务"再绑一件（本项目还没绑会话的叶子任务）；
/// "解除绑定"正在用它的那几件（以前用过它的不在这里解）；其余是会话的菜单（`SessionActions`，各处同一份）。
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
            if !link.bindable.isEmpty {
                Menu("绑定到任务", icon: .link) {
                    ForEach(link.bindable) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) {
                            let (sessionID, task) = (session.sessionID, item.task.id)
                            workspace.perform { try await $0.bindSession(sessionID, to: task) }
                        }
                    }
                }
            }
            let using = link.tasks.filter { $0.task.piSessionID == session.sessionID }
            if !using.isEmpty {
                Menu("解除绑定", icon: .unlink) {
                    ForEach(using) { item in
                        Button(Dotted(item.parent?.title, item.task.title).visible) { unbind(item.task.id) }
                    }
                }
            }
            Divider()
        }
        SessionActions(session: session, task: state.pin, ending: state.ending)
    }

    private func unbind(_ task: UUID) { workspace.perform { try await $0.unbindSession(from: task) } }
}
/// 会话属于的事（正在用它的与以前用过它的，含做完了的，先开始的在前）与本项目还能绑的。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    var tasks: [LeafTask]
    var bindable: [LeafTask]

    /// 标题里写的那一件：还没做完的第一件，都做完了是第一件。
    var primary: LeafTask? { tasks.first { $0.task.status != .done } ?? tasks.first }

    /// 会话名下面那一行"任务 · 子任务"（绑着好几件时后面"等 N 件"）：与会话名相同的一段不再写（从任务开的会话以叶子的标题命名），
    /// 什么都不剩时没有这一行。
    func path(below title: String) -> Dotted? {
        guard let primary else { return nil }
        let named = [primary.parent?.title, primary.task.title].filter { $0 != title }
        return Dotted(named + [tasks.count > 1 ? String(localized: "等 \(tasks.count) 件") : nil]).nonEmpty
    }

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        SessionTaskLink(tasks: try store.tasks(boundTo: sessionID), bindable: try store.bindableTasks(in: project))
    }
}

extension Workspace {
    /// 回到会话做的那件事：项目页，任务气泡翻到这一步（从点的那一下长出来）。
    func showTask(_ task: Card) {
        show(.project(task.projectID))
        open(task)
    }

    /// 完成会话绑着的任务：完成就是做完了，会话绑着的事都做完了就结束（见 `complete`）。
    func completeTask(_ id: UUID) {
        attempt { try await self.complete(id) }
    }
}
#endif

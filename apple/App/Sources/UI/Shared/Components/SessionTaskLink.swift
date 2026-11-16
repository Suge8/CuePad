import CueStore
import Foundation

nonisolated struct SessionTaskLink: Sendable, Equatable {
    struct Key: Equatable {
        var session: String?
        var project: UUID?
    }

    var tasks: [LeafTask]
    var bindable: [LeafTask]

    /// 会话绑着的事里没做完的。
    var open: [LeafTask] { tasks.filter { $0.task.status != .done } }
    var primary: LeafTask? { open.first ?? tasks.first }

    /// 与会话名相同的一段不再写（从任务开的会话以叶子的标题命名），什么都不剩时没有这一行。
    func path(below title: String) -> Dotted? {
        guard let primary else { return nil }
        let named = [primary.parent?.title, primary.task.title].filter { $0 != title }
        return Dotted(named + [tasks.count > 1 ? String(localized: "等 \(tasks.count) 件") : nil]).nonEmpty
    }

    static func read(sessionID: String, project: UUID?, from store: isolated CueStore) throws -> SessionTaskLink {
        SessionTaskLink(tasks: try store.tasks(boundTo: sessionID), bindable: try store.bindableTasks(in: project))
    }
}


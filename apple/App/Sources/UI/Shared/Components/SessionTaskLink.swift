import CueStore
import Foundation

/// 会话属于的事（正在用它的与以前用过它的，含做完了的，先开始的在前）与本项目还能绑的。
nonisolated struct SessionTaskLink: Sendable, Equatable {
    struct Key: Equatable {
        var session: String?
        var project: UUID?
    }

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


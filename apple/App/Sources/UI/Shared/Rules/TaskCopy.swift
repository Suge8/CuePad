import CueStore
import Foundation

nonisolated struct TaskFold: Equatable, Sendable {
    var showsAll = false
    var showsDone = false

    static func folded(_ tree: TaskTree, limit: Int) -> [UUID] {
        let roots = tree.roots
        let active = Set(roots.filter { root in tree.rows(of: [root]).contains { $0.task.status == .inProgress } })
        var room = max(limit - active.count, 0)
        let kept = roots.filter { root in
            if active.contains(root) { return true }
            room -= 1
            return room >= 0
        }
        return roots.count - kept.count > 1 ? kept : roots
    }
}

enum TaskCopy {
    static func more(hidden: Int, expanded: Bool) -> String { expanded ? String(localized: "收起") : String(localized: "还有 \(hidden) 条") }
    static func done(_ count: Int) -> String { String(localized: "已完成 \(count)") }

    static func progress(_ subtasks: TaskProgress) -> String { String(localized: "子任务 \(subtasks.done)/\(subtasks.total)") }

    static func hasOpen(_ subtasks: TaskProgress?) -> Bool { subtasks.map { $0.done < $0.total } ?? false }
    static func openSubtasks(_ subtasks: TaskProgress?) -> String {
        String(localized: "还有 \(subtasks.map { $0.total - $0.done } ?? 0) 个子任务没完成，一起完成？")
    }
}

enum TaskSpeech {
    static func value(_ status: TaskStatus?) -> String {
        switch status {
        case .todo: String(localized: "待办")
        case .inProgress: String(localized: "进行中")
        case .done: String(localized: "已完成")
        case nil: String(localized: "灵感")
        }
    }

    static func toggle(done: Bool) -> String { done ? String(localized: "标为未完成") : String(localized: "标为完成") }
}

import CueStore
import Foundation

/// 只多一条时直接全列："还有 1 条"那一行与一条任务一样高，折起来不省地方。
/// 收起其余任务一步到位，纸底那一行留在原来的屏幕位置（`TaskFoldAnchor`）。页面本地的临时状态，不持久化。
nonisolated struct TaskFold: Equatable, Sendable {
    var showsAll = false
    var showsDone = false

    static func hidden(_ count: Int, limit: Int) -> Int { count - limit > 1 ? count - limit : 0 }

    func shown(_ roots: [UUID], limit: Int) -> [UUID] {
        showsAll || Self.hidden(roots.count, limit: limit) == 0 ? roots : Array(roots.prefix(limit))
    }

    static func foldedRows(_ tree: TaskTree, limit: Int) -> Int {
        tree.rows(of: Array(tree.roots.prefix(limit))).count
    }
}

enum TaskCopy {
    /// 数都来自 `TaskCounts`，纸上不另摆分数。
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

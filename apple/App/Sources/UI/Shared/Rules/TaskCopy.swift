import CueStore
import Foundation

/// 项目页任务纸的开合（Mac 与 iOS 同一套）：纸里先列前 `limit` 条没做完的顶层任务（连同步骤），多出的折起，纸底"还有 N 条"在纸里原地展开、
/// 展开后这一格换成"收起"；只多一条时直接全列——"还有 1 条"那一行与一条任务一样高，折起来不省地方。
/// "已完成 M"原地展开本项目最近完成的顶层任务（`ProjectPageData.done`，样子与点圆圈回到待办同任务看板），与上面各自开合。
/// 收起其余任务一步到位，纸底那一行留在原来的屏幕位置（`TaskFoldAnchor`）。
/// 页面本地的临时状态，不持久化；总表（任务面板、任务页）只从书架、侧栏、工具栏进，项目页不跳过去。
nonisolated struct TaskFold: Equatable, Sendable {
    var showsAll = false
    var showsDone = false

    /// 折起时藏着几条；0 是不折、全列。
    static func hidden(_ count: Int, limit: Int) -> Int { count - limit > 1 ? count - limit : 0 }

    /// 纸里列出的顶层任务。
    func shown(_ roots: [UUID], limit: Int) -> [UUID] {
        showsAll || Self.hidden(roots.count, limit: limit) == 0 ? roots : Array(roots.prefix(limit))
    }
}

/// 步骤进度与完成上级时的确认，项目页任务纸底的开合（Mac 与 iOS 同一套）。草稿不写条数：写好了的在行尾是"开始"（`TaskNext`）。
enum TaskCopy {
    /// 纸底展开其余没做完的任务那一格（`TaskFold`）：折着写"还有 2 条"，展开后写"收起"。数都来自 `TaskCounts`，纸上不另摆分数。
    static func more(hidden: Int, expanded: Bool) -> String { expanded ? "收起" : "还有 \(hidden) 条" }
    /// 纸底展开最近完成那一格。
    static func done(_ count: Int) -> String { "已完成 \(count)" }

    static func progress(_ subtasks: TaskProgress) -> String { "步骤 \(subtasks.done)/\(subtasks.total)" }

    static func hasOpen(_ subtasks: TaskProgress?) -> Bool { subtasks.map { $0.done < $0.total } ?? false }
    static func openSubtasks(_ subtasks: TaskProgress?) -> String {
        "还有 \(subtasks.map { $0.total - $0.done } ?? 0) 个步骤没完成，一起完成？"
    }
}

/// 任务行给读屏的文案（Mac 与 iOS 同一套）：整行一个元素，标签是任务内容，值是状态，默认动作切换完成。
enum TaskSpeech {
    static func value(_ status: TaskStatus?) -> String {
        switch status {
        case .todo: "待办"
        case .inProgress: "进行中"
        case .done: "已完成"
        case nil: "灵感"
        }
    }

    static func toggle(done: Bool) -> String { done ? "标为未完成" : "标为完成" }
}

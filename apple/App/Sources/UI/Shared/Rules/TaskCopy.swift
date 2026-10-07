import CueStore

/// 子任务进度与完成上级时的确认（Mac 与 iOS 同一套）。
enum TaskCopy {
    static func progress(_ subtasks: TaskProgress) -> String { "子任务 \(subtasks.done)/\(subtasks.total)" }
    static func hasOpen(_ subtasks: TaskProgress?) -> Bool { subtasks.map { $0.done < $0.total } ?? false }
    static func openSubtasks(_ subtasks: TaskProgress?) -> String {
        "还有 \(subtasks.map { $0.total - $0.done } ?? 0) 个子任务没完成，一起完成？"
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

    static func value(done: Bool) -> String { done ? "已完成" : "未完成" }
    static func toggle(done: Bool) -> String { done ? "标为未完成" : "标为完成" }
}

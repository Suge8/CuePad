import CueStore

/// 子任务进度与完成上级时的确认（Mac 与 iOS 同一套）。
enum TaskCopy {
    /// 项目页任务纸列出前几条没做完的顶层任务，纸底这一行写没列出的："还有 2 条 · 已完成 1"（都没有时不写）。数都来自 `TaskCounts`，纸上不另摆分数。
    static func more(hidden: Int, done: Int) -> Dotted? {
        Dotted(hidden > 0 ? "还有 \(hidden) 条" : nil, done > 0 ? "已完成 \(done)" : nil).nonEmpty
    }

    static func progress(_ subtasks: TaskProgress) -> String { "子任务 \(subtasks.done)/\(subtasks.total)" }

    /// 任务行的进度一行："3 条提示词 · 1 已回复 · 子任务 1/2"；都没有时不写。所在项目与会话状态另起一行，不挤在这里。
    static func counts(_ marks: [ChildMark]?) -> Dotted? {
        ((PromptTally(marks).text ?? Dotted()) + Dotted(TaskProgress.subtasks(in: marks).map(progress))).nonEmpty
    }
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

    static func toggle(done: Bool) -> String { done ? "标为未完成" : "标为完成" }

    /// 进度念屏幕上那一行（`TaskCopy.counts`）："3 条提示词，1 已回复，子任务 1/2"；不另拼合计。
    static func progress(_ marks: [ChildMark]?) -> String? { TaskCopy.counts(marks)?.spoken }
}

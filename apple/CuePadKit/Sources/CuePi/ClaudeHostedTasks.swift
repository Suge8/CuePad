#if os(macOS)
import CueStore
import CueText
import Foundation

/// 托管会话在飞的工作，只按 Claude Code 自己给的后台任务清单（`background_tasks_changed`，每次整份：后台子代理、后台命令、
/// 子代理名下的后台命令带 `parent_task_id`；前台的不在里面）。任务落定（`task_notification`）本身不算交回：
/// - 顶层任务落定后主会话一定为它再跑一轮（`system/init` … `result`，`origin.kind` 为 task-notification；主会话这一轮在跑时并进这一轮），
///   所以落定即算主会话在跑，直到那一轮的 `result`——否则清单变空到那一轮开始之间会误报一次歇下；
/// - 子代理交回中途结果（报 completed、名下还有后台命令）后，那条命令做完时它以同一 id 再跑：命令的通知先到、清单先变空、它才重新出现，
///   这中间它仍算在飞。被停下的不会再跑。
struct ClaudeHostedTasks {
    private var listed: Set<String> = []
    /// 清单里出现过的顶层任务（没有 `parent_task_id`）
    private var topLevel: Set<String> = []
    /// 子任务 → 它所属的子代理
    private var owner: [String: String] = [:]
    /// 交回过中途结果、名下任务做完时会再跑的子代理
    private var paused: Set<String> = []
    /// 名下任务刚做完、还没重新出现在清单里的子代理
    private var resuming: Set<String> = []

    var inFlight: Set<String> { listed.union(resuming) }

    mutating func list(_ tasks: [JSONValue]) {
        listed = Set(tasks.compactMap { $0["task_id"]?.string })
        for task in tasks {
            guard let id = task["task_id"]?.string else { continue }
            if let parent = task["parent_task_id"]?.string { owner[id] = parent } else { topLevel.insert(id) }
        }
        resuming.subtract(listed)
        paused.subtract(listed)
    }

    /// 一个任务落定（`completed`：做完或交回了中途结果；否则被停下或失败）；返回主会话是否会为它跑一轮。
    mutating func settled(_ id: String, completed: Bool) -> Bool {
        if completed { paused.insert(id) } else { paused.remove(id) }
        if let parent = owner[id], paused.remove(parent) != nil { resuming.insert(parent) }
        return topLevel.contains(id)
    }
}
#endif

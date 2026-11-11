#if os(macOS)
import CueStore
import CueText
import Foundation

/// 托管会话在飞的工作，只按 Claude Code 自己给的后台任务清单（`background_tasks_changed`，每次整份：后台子代理、后台命令、
/// 子代理名下的后台命令带 `parent_task_id`；前台的不在里面）。任务落定（`task_notification`）本身不算交回：
/// - 顶层任务落定后主会话为它单独再跑一轮，那一轮的 `result` 带 `origin: {kind: "task-notification", runId}`，`runId` 就是通知的 `run_id`。
///   落定之后主会话一直算在跑（`owedSince`），直到带这个编号的 `result`，别的轮收尾不算。那一轮从任务的结束时刻算起（通知前那条 `task_updated`
///   的 `end_time`，Claude Code 自己的钟，一定早于那一轮，见 `SessionFacts.startTurn`）；收到通知或 `result` 的此刻不行：假模型下一轮只要几毫秒，
///   读得慢时晚于下一轮写下的回答（实测晚过 74 毫秒）。2.1.318 实测的消息顺序（托管子代理三例各 60 遍，压 CPU 与不压各半）：
///   - 通知落在正在跑的一轮里（你让它停掉子代理的那一轮）：`task_notification`、清单变空、这一轮的 `result`（不带编号）、`init` … 带编号的 `result`。
///     只认先后时这一轮的 `result` 就报歇下，下一轮马上又报在跑，你收到两次歇下；
///   - 交回过报告的子代理落定：先跑一轮收它的报告（`origin.kind` 为 peer），带编号的那一轮不调模型（`num_turns` 0），`result` 跟在后面。
///   以前装着 CuePad 的钩子时钩子拖慢了这一轮的收尾，通知总在它的 `result` 之后到，所以没露出来。没见过通知并进当前一轮、不再单独跑的；
///   你停下这一轮时 Claude Code 可能连排着的通知一起取消，所以停下就不再等它（`forgetOwed`），不会卡在在跑；
/// - 子代理交回中途结果（报 completed、名下还有后台命令）后，那条命令做完时它以同一 id 再跑：命令的通知先到、清单先变空、它才重新出现，
///   这中间它仍算在飞。被停下的不会再跑。
struct ClaudeHostedTasks {
    private var listed: Set<String> = []
    private var topLevel: Set<String> = []
    private var owner: [String: String] = [:]
    /// 交回过中途结果、名下任务做完时会再跑的子代理
    private var paused: Set<String> = []
    /// 名下任务刚做完、还没重新出现在清单里的子代理
    private var resuming: Set<String> = []
    /// 顶层任务落定后、主会话为它跑的那一轮还没收尾的通知（`run_id`）与任务的结束时刻
    private var owed: [String: Date] = [:]
    private var ended: [String: Date] = [:]

    var inFlight: Set<String> { listed.union(resuming) }
    var owedSince: Date? { owed.values.min() }

    mutating func list(_ tasks: [JSONValue]) {
        listed = Set(tasks.compactMap { $0["task_id"]?.string })
        for task in tasks {
            guard let id = task["task_id"]?.string else { continue }
            if let parent = task["parent_task_id"]?.string { owner[id] = parent } else { topLevel.insert(id) }
        }
        resuming.subtract(listed)
        paused.subtract(listed)
    }

    /// `task_updated` 带来的结束时刻（毫秒）
    mutating func ended(_ id: String, at milliseconds: Double) { ended[id] = Date(timeIntervalSince1970: milliseconds / 1000) }

    /// 一个任务落定（`completed`：做完或交回了中途结果；否则被停下或失败）；主会话要为它跑一轮时返回那一轮的开始。
    mutating func settled(_ id: String, run: String?, completed: Bool, at now: Date) -> Date? {
        if completed { paused.insert(id) } else { paused.remove(id) }
        if let parent = owner[id], paused.remove(parent) != nil { resuming.insert(parent) }
        let end = ended.removeValue(forKey: id) ?? now
        guard topLevel.contains(id) else { return nil }
        if let run { owed[run] = end }
        return end
    }

    /// 一条 `result`：为某个通知跑的那一轮收尾了；返回它是不是。
    mutating func answered(_ result: JSONValue) -> Bool {
        guard result["origin"]?["kind"]?.string == "task-notification" else { return false }
        if let run = result["origin"]?["runId"]?.string { owed[run] = nil }
        return true
    }

    mutating func forgetOwed() { owed = [:] }
}
#endif

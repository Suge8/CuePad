import CueStore
import Foundation

/// 任务行尾那一格时间（`TaskLine`），只给进行中的任务：有子任务、已做完至少一步且量得出用时的，估还要多久——做完的子任务平均每步用时
/// （各步从自己开始到做完，`TaskProgress.stepTime`）乘剩下的步数，写"约 N 分钟"；没有这个依据的写已经跑了多久（只写时长，从任务开始算，
/// `Card.startedAt`，`PiClock.Elapsed`）。只读库里现成的开始与完成时刻，不另存。时长就是全 App 那一种写法（`PiClock.duration`）。
nonisolated enum TaskPace: Equatable {
    case left(TimeInterval)
    case ran(since: Date)

    static func of(_ task: Card, steps: TaskProgress?) -> TaskPace? {
        guard task.status == .inProgress, let start = task.startedAt else { return nil }
        if let steps, steps.done > 0, steps.done < steps.total, let each = steps.stepTime {
            return .left(each * Double(steps.total - steps.done))
        }
        return .ran(since: start)
    }

    static func left(_ seconds: TimeInterval) -> String { String(localized: "约 \(PiClock.duration(seconds))") }
}

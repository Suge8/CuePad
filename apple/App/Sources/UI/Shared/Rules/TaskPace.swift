import CueStore
import Foundation

/// 任务行尾那一格时间（`TaskLine`），只给进行中的任务：有步骤、已做完至少一步且量得出用时的，估还要多久——做完的步骤平均每步用时
/// （各步从自己开始到做完，`TaskProgress.stepTime`）乘剩下的步数，写"约 N 分钟"；没有这个依据的写已经跑了多久（"已跑 N 分钟"，从任务开始算，`Card.startedAt`）。
/// 只读库里现成的开始与完成时刻，不另存。两种都只写到分钟（不足一分钟算一分钟，`minutes`），行尾的时间只有这一种写法。
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

    /// 整分钟数，不足一分钟算一分钟。
    static func minutes(_ seconds: TimeInterval) -> Int { max(Int((seconds / 60).rounded(.up)), 1) }

    static func left(_ seconds: TimeInterval) -> String { "约 \(minutes(seconds)) 分钟" }

    /// 已经跑了多久，按时刻换字（`LiveText`）：每过一整分钟换一次。
    struct Ran: DiscreteFormatStyle {
        let since: Date

        func format(_ now: Date) -> String { "已跑 \(TaskPace.minutes(now.timeIntervalSince(since))) 分钟" }

        func discreteInput(after now: Date) -> Date? { since.tick(every: 60, after: now) }

        func discreteInput(before now: Date) -> Date? { since.tick(every: 60, after: now).addingTimeInterval(-60.001) }
    }
}

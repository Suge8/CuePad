import CueStore
import Foundation

/// 任务行尾那一格时间（`TaskLine`），只给进行中的任务：有步骤、已做完至少一步且量得出用时的，估还要多久——做完的步骤平均每步用时
/// （各步从自己开始到做完，`TaskProgress.stepTime`）乘剩下的步数，写"约 N 分钟"；没有这个依据的写已经跑了多久（"已跑 N 分钟"，从任务开始算，`Card.startedAt`）。
/// 只读库里现成的开始与完成时刻，不另存。时长就是全 App 那一种写法（`PiClock.duration`，满 60 分钟进小时、再进天），这里只加前缀。
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

    static func left(_ seconds: TimeInterval) -> String { "约 \(PiClock.duration(seconds))" }

    /// 已经跑了多久，按时刻换字（`LiveText`）：换字的时刻同走字的会话计时（`PiClock.Style.header`：第一分钟每秒、一小时内每整分钟、再往后每整小时），
    /// 字跟着时长写法走到哪一档。
    struct Ran: DiscreteFormatStyle {
        let since: Date

        private var clock: PiClock.Live { PiClock.running(since: since).live(.header) }

        func format(_ now: Date) -> String { "已跑 \(PiClock.duration(now.timeIntervalSince(since)))" }

        func discreteInput(after now: Date) -> Date? { clock.discreteInput(after: now) }

        func discreteInput(before now: Date) -> Date? { clock.discreteInput(before: now) }
    }
}

import CueStore
import Foundation

/// 任务行尾那一格时间（`TaskLine`），只给进行中的任务：有步骤、已做完至少一步的估还要多久——做完的步骤平均用时
/// （从任务开始到最近一步做完，除以做完的步数）乘剩下的步数，写"约 N 分钟"；没有这个依据的写已经跑了多久（"已跑 N 分钟"，从任务开始算）。
/// 只读库里现成的开始与完成时刻（`Card.startedAt`、`TaskProgress.lastDone`），不另存；时长的写法同全 App（`PiClock.duration`）。
nonisolated enum TaskPace: Equatable {
    case left(TimeInterval)
    case ran(since: Date)

    static func of(_ task: Card, steps: TaskProgress?) -> TaskPace? {
        guard task.status == .inProgress, let start = task.startedAt else { return nil }
        if let steps, steps.done > 0, steps.done < steps.total, let last = steps.lastDone {
            let spent = last.timeIntervalSince(start)
            if spent > 0 { return .left(spent / Double(steps.done) * Double(steps.total - steps.done)) }
        }
        return .ran(since: start)
    }

    /// "约 N 分钟"；跑了多久的走字见 `Ran`。
    static func left(_ seconds: TimeInterval) -> String { "约 \(PiClock.duration(seconds))" }

    /// 已经跑了多久，按时刻换字（`LiveText`）：第一分钟写"刚开始"，之后"已跑 N 分钟"，换字的时刻同只写时长的会话计时（`PiClock.Style.span`）。
    struct Ran: DiscreteFormatStyle {
        let since: Date

        private var clock: PiClock.Live { PiClock.running(since: since).live(.span) }

        func format(_ now: Date) -> String {
            let elapsed = now.timeIntervalSince(since)
            return elapsed < 60 ? "刚开始" : "已跑 \(PiClock.duration(elapsed))"
        }

        func discreteInput(after now: Date) -> Date? { clock.discreteInput(after: now) }

        func discreteInput(before now: Date) -> Date? { clock.discreteInput(before: now) }
    }
}

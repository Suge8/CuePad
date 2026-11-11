import CueStore
import Foundation

/// 只读库里现成的开始与完成时刻，不另存。
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

    static func left(_ seconds: TimeInterval) -> String { String(localized: "约 \(SessionClock.duration(seconds))") }
}

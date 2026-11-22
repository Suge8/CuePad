#if os(macOS)
import CueStore
import Foundation

nonisolated struct CueTiming: Sendable {
    var patrolAfter: Duration = .seconds(2 * 3600)
    var warmPatrolAfter: Duration = .seconds(20 * 60)
    var cacheMargin: Duration = .seconds(5 * 60)
    /// 提示缓存的时长（Claude Code 与 Pi 的大脑开了 1 小时的，见 `ClaudeCodeHost+Brain`、`PiBrain`）：距上一次模型请求超过它，缓存已过期，醒来就换新。
    var cacheLifetime: Duration = .seconds(3600)
    var renewAt = CueContext.renewAt
    var restarts: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
    var slowRestarts: [Duration] = [.seconds(5 * 60), .seconds(15 * 60), .seconds(30 * 60)]
    var silence: Duration = .seconds(10 * 60)
    var awake: @Sendable () -> SuspendingClock.Instant = { .now }
    var returnRetry: Duration = .seconds(30)
    var retryWake: Duration = .seconds(120)
    var sayWait: TimeInterval = Speech.cueWait
    var quietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]
    var clock: @Sendable () -> Date = { .now }

    func restartDelay(after failures: Int) -> Duration {
        failures <= restarts.count ? restarts[failures - 1] : slowDelay(after: failures - restarts.count)
    }

    func slowDelay(after n: Int) -> Duration { slowRestarts[min(n, slowRestarts.count) - 1] }

    func isDown(after failures: Int) -> Bool { failures > restarts.count }

    func isQuiet(_ date: Date) -> Bool { quietHours.contains(Calendar.current.component(.hour, from: date)) }

    func awake(from date: Date) -> Date? {
        guard isQuiet(date) else { return date }
        guard var hour = Calendar.current.dateInterval(of: .hour, for: date)?.end else { return nil }
        for _ in 0..<24 {
            if !isQuiet(hour) { return hour }
            hour += 3600
        }
        return nil
    }
}
#endif

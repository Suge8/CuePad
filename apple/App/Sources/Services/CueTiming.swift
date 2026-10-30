#if os(macOS)
import CueStore
import Foundation

/// 管理器的时间规则；测试缩短它们。
nonisolated struct CueTiming: Sendable {
    /// 你这么久没说话、又没有在做的事，才巡视（冷巡视：缓存多半已过期，醒来就换新）。
    var patrolAfter: Duration = .seconds(2 * 3600)
    /// 热巡视：你这么久没说话、提示缓存还热（距上一次模型请求不到 `cacheLifetime - cacheMargin`）就趁热看一眼，接着用缓存几乎不花钱。
    var warmPatrolAfter: Duration = .seconds(20 * 60)
    /// 热巡视要在缓存过期前这么久开始：一轮要几次模型请求，开始时才热、做到一半过期就白热了。
    var cacheMargin: Duration = .seconds(5 * 60)
    /// 提示缓存的时长（Claude Code 与 Pi 的大脑开了 1 小时的，见 `ClaudeCodeHost+Brain`、`PiBrain`）：距上一次模型请求超过它，缓存已过期，醒来就换新。
    var cacheLifetime: Duration = .seconds(3600)
    /// 换新线（token）：上下文用到它，醒来就换新。数与理由见 `CueContext.renewAt`。
    var renewAt = CueContext.renewAt
    /// 大脑意外退出或起不来后，第 n 次重试前等多久：先快（多是偶发），用完转慢（`slowRestarts`）。
    var restarts: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
    /// 快的用完之后的重试间隔，最后一个一直用下去：起不来不停在终态，网络、登录恢复了自己接上；你发消息时不等它，马上再试。
    var slowRestarts: [Duration] = [.seconds(5 * 60), .seconds(15 * 60), .seconds(30 * 60)]
    /// 看门狗：一轮里这么久没有任何大脑事件，就当大脑挂了（停掉重起，交出去的话重新交）。Cue 的工具都在几十秒内回（说话最长 `sayWait`）。
    var silence: Duration = .seconds(10 * 60)
    /// Cue 自己醒来的一轮出错后，隔这么久再醒一次（只一次）。
    var retryWake: Duration = .seconds(120)
    /// Cue 的说话工具（say、answer）写下请求后等结果多久（`cuepad mcp --wait`）。
    var sayWait: TimeInterval = Speech.cueWait
    /// 打扰时段（本地钟点）：不巡视。通知不看它，免打扰只认系统的专注模式。
    var quietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]
    /// 信封第一行写的此刻（记忆基准评测把它定在题目的提问时刻）；别的时间规则都照真实时钟。
    var clock: @Sendable () -> Date = { .now }

    /// 连续第 `failures` 次失败后等多久再起。
    func restartDelay(after failures: Int) -> Duration {
        failures <= restarts.count ? restarts[failures - 1] : slowRestarts[min(failures - restarts.count, slowRestarts.count) - 1]
    }

    /// 快的重试用完了：这时才算起不来（告诉你一次，此刻的状态是出错）。
    func isDown(after failures: Int) -> Bool { failures > restarts.count }

    func isQuiet(_ date: Date) -> Bool { quietHours.contains(Calendar.current.component(.hour, from: date)) }

    /// `date` 起第一个不在打扰时段的时刻（落在打扰时段里就是它结束的那个整点）；一天都是打扰时段为 nil。
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

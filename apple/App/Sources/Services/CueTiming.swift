#if os(macOS)
import CueStore
import Foundation

/// 管理器的时间规则；测试缩短它们。
nonisolated struct CueTiming: Sendable {
    /// 你这么久没说话、又没有在做的事，才巡视。
    var patrolAfter: Duration = .seconds(2 * 3600)
    /// 记忆有待合并的块时，空闲这么久才叫它合并。
    var mergeAfter: Duration = .seconds(600)
    /// 大脑意外退出或起不来后，第 n 次重试前等多久；都失败就停在"起不来"。
    var restarts: [Duration] = [.seconds(2), .seconds(10), .seconds(60)]
    /// Cue 自己醒来的一轮出错后，隔这么久再醒一次（只一次）。
    var retryWake: Duration = .seconds(120)
    /// Cue 的说话工具（say、answer）写下请求后等结果多久（`cuepad mcp --wait`）。
    var sayWait: TimeInterval = Speech.cueWait
    /// 打扰时段（本地钟点）：不巡视。通知不看它，免打扰只认系统的专注模式。
    var quietHours: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6, 7]

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

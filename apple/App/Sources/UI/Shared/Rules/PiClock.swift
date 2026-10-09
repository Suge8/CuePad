import CueStore
import Foundation

/// 会话计时怎么读（Mac 与手机同一条）：工作中"已运行"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"已等"从进入等待算，话还在路上（会话没在跑时）"已发出"从发出算，空闲、出错、已结束是"多久前"。哪一种由 `PiShown` 定。
nonisolated enum PiClock: Hashable, Sendable {
    case running(since: Date)
    case waiting(since: Date)
    case sent(since: Date)
    case ago(Date)

    static func reading(_ state: Open<PiWorkState>, stateSince: Date, busySince: Date?) -> PiClock {
        if state == .known(.waitingForUser) { return .waiting(since: stateSince) }
        // 旧版本写的记录没有 busySince：退回进入当前状态的时间
        if state.isWorking { return .running(since: busySince ?? stateSince) }
        return .ago(stateSince)
    }

    /// 全 App 唯一的时长写法，不跳秒："42 秒"、"4 分"、"2 小时 5 分"、整小时"3 小时"（处理中的活跃感交给转圈）。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 1)
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600) 小时" : "\(total / 3600) 小时 \(minutes) 分"
    }

    /// 超过这么久的"多久前"按日历天写（"昨天"、"4 天前"），不写成几十个小时。
    private static let calendarAfter: TimeInterval = 86_400

    var since: Date {
        switch self {
        case .running(let since), .waiting(let since), .sent(let since), .ago(let since): since
        }
    }

    func text(now: Date, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(since)
        switch self {
        case .running: return "已运行 \(Self.duration(elapsed))"
        case .waiting: return "已等 \(Self.duration(elapsed))"
        case .sent: return "已发出 \(Self.duration(elapsed))"
        case .ago(let date):
            if elapsed >= Self.calendarAfter {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 1
                return days <= 1 ? "昨天" : "\(days) 天前"
            }
            return "\(Self.duration(elapsed))前"
        }
    }

    /// 文字下一次会变的时刻：一分钟内每秒，之后每整分钟，一天以上每小时。
    func nextChange(after now: Date) -> Date {
        let elapsed = max(now.timeIntervalSince(since), 0)
        let step: TimeInterval = elapsed < 60 ? 1 : elapsed < Self.calendarAfter ? 60 : 3600
        return since.addingTimeInterval((elapsed / step).rounded(.down) * step + step)
    }
}

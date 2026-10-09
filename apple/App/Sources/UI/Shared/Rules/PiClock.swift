import CueStore
import Foundation

/// 会话计时怎么读（Mac 与手机同一条）：工作中"已运行"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"已等"从进入等待算，话还在路上（会话没在跑时）"已发出"从发出算，空闲、出错、已结束是"多久前"（`DateLabel`）。哪一种由 `PiShown` 定。
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

    /// 全 App 唯一的时长写法，不跳秒，粗到小时（与 `DateLabel` 同一粒度）："42 秒"、"4 分"、"3 小时"（处理中的活跃感交给转圈）。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 1)
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分" }
        return "\(total / 3600) 小时"
    }

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
        case .ago(let date): return DateLabel.short(date, now: now, calendar: calendar)
        }
    }

    /// 文字下一次会变的时刻：一分钟内每秒，一小时内每整分钟，之后每小时。
    func nextChange(after now: Date) -> Date {
        let elapsed = max(now.timeIntervalSince(since), 0)
        let step: TimeInterval = elapsed < 60 ? 1 : elapsed < 3600 ? 60 : 3600
        return since.addingTimeInterval((elapsed / step).rounded(.down) * step + step)
    }
}

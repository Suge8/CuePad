import CueStore
import Foundation
import SwiftUI

/// 会话计时怎么读（Mac 与手机同一条）：工作中"已运行"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"已等"从进入等待算，话还在路上（会话没在跑时）"已发出"从发出算，空闲、出错、已结束是"多久前"（`DateLabel`）。哪一种由 `PiShown` 定。
/// 走字的计时交给系统计时文本（`live`）：系统只在文字会变的时刻更新它，不经 TimelineView 或定时器重算视图。
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

    static let locale = Locale(identifier: "zh-Hans")

    /// 全 App 唯一的时长写法，与系统计时文本（`live`）一字不差：只取最大的一个单位，"42秒钟"、"4分钟"、"3小时"（处理中的活跃感交给转圈）。
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(Int(seconds), 1))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1, fractionalPart: .hide(rounded: .down)).locale(locale))
    }

    var since: Date {
        switch self {
        case .running(let since), .waiting(let since), .sent(let since), .ago(let since): since
        }
    }

    /// 走字的计时前面那几个字；"多久前"没有（它不走字）。
    var prefix: String? {
        switch self {
        case .running: "已运行"
        case .waiting: "已等"
        case .sent: "已发出"
        case .ago: nil
        }
    }

    /// 此刻的文字（读屏、不走字的地方）。
    func text(now: Date, calendar: Calendar = .current) -> String {
        guard let prefix else { return DateLabel.short(since, now: now, calendar: calendar) }
        return "\(prefix) \(Self.duration(now.timeIntervalSince(since)))"
    }

    /// 系统计时文本：从 `since` 往上数，只显示最大的一个单位，写法同 `duration`。
    var live: SystemFormatStyle.Timer {
        .timer(countingUpIn: since..<Date.distantFuture, maxFieldCount: 1).locale(Self.locale)
    }

    /// "多久前"的系统时间文本：写法就是 `DateLabel`，系统只在文字会变的时刻（`Ago`）更新它。
    var ago: Ago { Ago(date: since) }

    /// 按 `DateLabel` 写"多久前"的格式：一小时内在整分钟变、一天内在整小时变，再往前在每天零点变（昨天、星期、月日）。
    struct Ago: DiscreteFormatStyle {
        let date: Date

        func format(_ now: Date) -> String { DateLabel.short(date, now: now) }

        func discreteInput(after now: Date) -> Date? { boundary(around: now).next }

        func discreteInput(before now: Date) -> Date? { boundary(around: now).last.addingTimeInterval(-0.001) }

        /// `now` 所在的那一段文字的起点与下一段的起点。
        private func boundary(around now: Date) -> (last: Date, next: Date) {
            let elapsed = max(now.timeIntervalSince(date), 0)
            guard elapsed >= 86_400 else {
                let step: TimeInterval = elapsed < 3600 ? 60 : 3600
                let last = date.addingTimeInterval((elapsed / step).rounded(.down) * step)
                return (last, last.addingTimeInterval(step))
            }
            let calendar = Calendar.current
            let midnight = calendar.startOfDay(for: now)
            return (midnight, calendar.date(byAdding: .day, value: 1, to: midnight) ?? now.addingTimeInterval(86_400))
        }
    }
}

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

    /// "多久前"的文字下一次会变的时刻：一小时内每整分钟（"刚刚"到"1 分前"也在整分钟），之后每小时。
    func nextChange(after now: Date) -> Date {
        let elapsed = max(now.timeIntervalSince(since), 0)
        let step: TimeInterval = elapsed < 3600 ? 60 : 3600
        return since.addingTimeInterval((elapsed / step).rounded(.down) * step + step)
    }
}

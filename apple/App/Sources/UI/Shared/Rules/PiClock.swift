import CueStore
import Foundation
import SwiftUI

/// 会话计时怎么读（Mac 与手机同一条）：工作中"已运行"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"已等"从进入等待算，话还在路上（会话没在跑时）"已发出"从发出算，空闲、出错、已结束是"多久前"（`DateLabel`）。哪一种由 `PiShown` 定。
/// 怎么写只在这里：列表里（Agent 页、侧栏、项目"此刻"、书架）只到分钟、第一分钟写"不到 1 分钟"，不每秒换字；
/// 只有会话页顶栏那一个计时到秒（`Precision`）。界面里是系统时间文本（`live`）：系统只在文字会变的时刻更新它，不经 TimelineView 或定时器重算视图。
nonisolated enum PiClock: Hashable, Sendable, Codable {
    case running(since: Date)
    case waiting(since: Date)
    case sent(since: Date)
    case ago(Date)

    /// 走字的计时写到哪一位：列表里到分钟，会话页顶栏到秒。
    enum Precision: Hashable, Codable, Sendable { case minute, second }

    /// 工作中的记录总带着这段处理的起点（`busySince`，Mac 的状态记录器写入时保证）；万一没有就不写计时，不拿别的时刻冒充。
    static func reading(_ state: Open<PiWorkState>, stateSince: Date, busySince: Date?) -> PiClock? {
        if state == .known(.waitingForUser) { return .waiting(since: stateSince) }
        if state.isWorking { return busySince.map(PiClock.running(since:)) }
        return .ago(stateSince)
    }

    /// 全 App 唯一的时长写法：只取最大的一个单位，"42 秒"、"4 分钟"、"3 小时"（处理中的活跃感交给转圈）；
    /// 到分钟时第一分钟写"不到 1 分钟"。数字与单位之间空一格，与"24 条灵感""11 分前"同一种排法；
    /// 不用系统的单位格式：中文的宽格式把秒写成"秒钟"、数字与单位之间不空。
    static func duration(_ seconds: TimeInterval, precision: Precision = .second) -> String {
        let whole = max(Int(seconds), 1)
        if whole < 60 { return precision == .minute ? "不到 1 分钟" : "\(whole) 秒" }
        if whole < 3600 { return "\(whole / 60) 分钟" }
        return "\(whole / 3600) 小时"
    }

    var since: Date {
        switch self {
        case .running(let since), .waiting(let since), .sent(let since), .ago(let since): since
        }
    }

    /// 走字的计时前面那几个字；"多久前"没有。
    var prefix: String? {
        switch self {
        case .running: "已运行"
        case .waiting: "已等"
        case .sent: "已发出"
        case .ago: nil
        }
    }

    /// 此刻的文字（读屏、不走字的地方，以及 `live` 的每一次更新）。
    func text(now: Date, precision: Precision = .minute, calendar: Calendar = .current) -> String {
        guard let prefix else { return DateLabel.short(since, now: now, calendar: calendar) }
        return "\(prefix) \(Self.duration(now.timeIntervalSince(since), precision: precision))"
    }

    /// 界面里的系统时间文本：`Text(.currentDate, format: clock.live(.minute))`。
    func live(_ precision: Precision) -> Live { Live(clock: self, precision: precision) }

    /// 计时的格式：文字就是 `text(now:precision:)`，并告诉系统下一次在什么时刻会变——到秒的第一分钟每秒，
    /// 之后（以及到分钟的）一小时内每整分钟、再往后每整小时；"多久前"一小时内每整分钟、一天内每整小时、再往前每天零点。
    struct Live: DiscreteFormatStyle {
        let clock: PiClock
        let precision: Precision

        func format(_ now: Date) -> String { clock.text(now: now, precision: precision) }

        func discreteInput(after now: Date) -> Date? { segment(around: now).next }

        func discreteInput(before now: Date) -> Date? { segment(around: now).start.addingTimeInterval(-0.001) }

        /// `now` 所在那一段文字的起点与下一段的起点。
        private func segment(around now: Date) -> (start: Date, next: Date) {
            let since = clock.since
            let elapsed = max(now.timeIntervalSince(since), 0)
            if clock.prefix == nil, elapsed >= 86_400 {
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: now)
                return (midnight, calendar.date(byAdding: .day, value: 1, to: midnight) ?? now.addingTimeInterval(86_400))
            }
            let step: TimeInterval = elapsed < 60 && precision == .second && clock.prefix != nil ? 1 : elapsed < 3600 ? 60 : 3600
            let start = since.addingTimeInterval((elapsed / step).rounded(.down) * step)
            return (start, start.addingTimeInterval(step))
        }
    }
}

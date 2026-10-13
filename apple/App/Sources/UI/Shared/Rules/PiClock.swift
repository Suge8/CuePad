import CueStore
import Foundation
import SwiftUI

/// 会话计时怎么读（Mac 与手机同一条）：工作中"运行了 4 分钟"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"等了 4 分钟"从进入等待算，话还在路上（会话没在跑时）"4 分钟前发出"从发出算，空闲、出错、已结束是"多久前"（`DateLabel`）。哪一种由 `PiShown` 定。
/// 怎么写只在这里：列表里（Agent 页、侧栏、项目"此刻"、书架）只到分钟、第一分钟写"刚开始 / 刚刚 / 刚发出"，不每秒换字；
/// 只有会话页顶栏那一个计时到秒，会话行只写时长（`Style`）。界面里是系统时间文本（`live`）：系统只在文字会变的时刻更新它，不经 TimelineView 或定时器重算视图。
nonisolated enum PiClock: Hashable, Sendable, Codable {
    case running(since: Date)
    case waiting(since: Date)
    case sent(since: Date)
    case ago(Date)

    /// 怎么写：`list` 按计时的种类带说法、走字到分钟（"运行了 4 分钟""刚开始""2 小时前"），任务行、书架、子代理用；
    /// `header` 同样的说法、走字的第一分钟到秒，只有会话页顶栏；`span` 只写在这个状态里待了多久（"刚刚""4 分钟""3 天"），
    /// 会话行用——一列卡片里只有一种写法，状态由状态词说。
    enum Style: Hashable, Codable, Sendable { case list, header, span }

    /// 工作中的记录总带着这段处理的起点（`busySince`，Mac 的状态记录器写入时保证）；万一没有就不写计时，不拿别的时刻冒充。
    static func reading(_ state: Open<PiWorkState>, stateSince: Date, busySince: Date?) -> PiClock? {
        if state == .known(.waitingForUser) { return .waiting(since: stateSince) }
        if state.isWorking { return busySince.map(PiClock.running(since:)) }
        return .ago(stateSince)
    }

    /// 全 App 唯一的时长写法：只取最大的一个单位，"42 秒"、"4 分钟"、"3 小时"、"2 天"（处理中的活跃感交给动效）。
    /// 数字与单位之间空一格，与"24 条灵感""11 分钟前"同一种排法；
    /// 不用系统的单位格式：中文的宽格式把秒写成"秒钟"、数字与单位之间不空。
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds), 1)
        if whole < 60 { return "\(whole) 秒" }
        if whole < 3600 { return "\(whole / 60) 分钟" }
        if whole < 86_400 { return "\(whole / 3600) 小时" }
        return "\(whole / 86_400) 天"
    }

    /// 走字的计时（不是"多久前"）。
    private var isRunningClock: Bool { if case .ago = self { false } else { true } }

    var since: Date {
        switch self {
        case .running(let since), .waiting(let since), .sent(let since), .ago(let since): since
        }
    }

    /// 此刻的文字（读屏、不走字的地方，以及 `live` 的每一次更新）：列表里（`.list`）不到一分钟写"刚开始"这类，不每秒换字。
    func text(now: Date, style: Style = .list, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(since)
        if style == .span { return elapsed < 60 ? "刚刚" : Self.duration(elapsed) }
        if case .ago = self { return DateLabel.short(since, now: now, calendar: calendar) }
        if style == .list, elapsed < 60 {
            switch self {
            case .running: return "刚开始"
            case .waiting: return "刚刚"
            default: return "刚发出"
            }
        }
        let duration = Self.duration(elapsed)
        return switch self {
        case .running: "运行了 \(duration)"
        case .waiting: "等了 \(duration)"
        default: "\(duration)前发出"
        }
    }

    /// 界面里的系统时间文本：`Text(.currentDate, format: clock.live(.list))`。
    func live(_ style: Style) -> Live { Live(clock: self, style: style) }

    /// 计时的格式：文字就是 `text(now:style:)`，并告诉系统下一次在什么时刻会变——顶栏走字的第一分钟每秒，
    /// 之后（以及列表里的）一小时内每整分钟、再往后每整小时；"多久前"一小时内每整分钟、一天内每整小时、再往前每天零点；
    /// 只写时长的（`span`）一小时内每整分钟、一天内每整小时、再往后每整天（从起点算）。
    struct Live: DiscreteFormatStyle {
        let clock: PiClock
        let style: Style

        func format(_ now: Date) -> String { clock.text(now: now, style: style) }

        func discreteInput(after now: Date) -> Date? { segment(around: now).next }

        func discreteInput(before now: Date) -> Date? { segment(around: now).start.addingTimeInterval(-0.001) }

        /// `now` 所在那一段文字的起点与下一段的起点。
        private func segment(around now: Date) -> (start: Date, next: Date) {
            let since = clock.since
            let elapsed = max(now.timeIntervalSince(since), 0)
            if style == .span {
                let step: TimeInterval = elapsed < 3600 ? 60 : elapsed < 86_400 ? 3600 : 86_400
                let start = since.addingTimeInterval((elapsed / step).rounded(.down) * step)
                return (start, start.addingTimeInterval(step))
            }
            if !clock.isRunningClock, elapsed >= 86_400 {
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: now)
                return (midnight, calendar.date(byAdding: .day, value: 1, to: midnight) ?? now.addingTimeInterval(86_400))
            }
            let step: TimeInterval = elapsed < 60 && style == .header && clock.isRunningClock ? 1 : elapsed < 3600 ? 60 : 3600
            let start = since.addingTimeInterval((elapsed / step).rounded(.down) * step)
            return (start, start.addingTimeInterval(step))
        }
    }
}

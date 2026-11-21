import CueStore
import Foundation
import SwiftUI

nonisolated enum SessionClock: Hashable, Sendable, Codable {
    case running(since: Date)
    case waiting(since: Date)
    case sent(since: Date)
    case ago(Date)

    enum Style: Hashable, Codable, Sendable { case list, header, span }

    static func reading(_ state: Open<WorkState>, stateSince: Date, busySince: Date?) -> SessionClock? {
        if state == .known(.waitingForUser) { return .waiting(since: stateSince) }
        if state.isWorking { return busySince.map(SessionClock.running(since:)) }
        return .ago(stateSince)
    }

    /// 全 App 唯一的时长写法。
    /// 不用系统的单位格式：中文的宽格式把秒写成"秒钟"、数字与单位之间不空。
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds), 1)
        if whole < 60 { return String(localized: "\(whole) 秒") }
        if whole < 3600 { return String(localized: "\(whole / 60) 分钟") }
        if whole < 86_400 { return String(localized: "\(whole / 3600) 小时") }
        return String(localized: "\(whole / 86_400) 天")
    }

    private var isRunningClock: Bool { if case .ago = self { false } else { true } }

    var since: Date {
        switch self {
        case .running(let since), .waiting(let since), .sent(let since), .ago(let since): since
        }
    }

    func text(now: Date, style: Style = .list, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(since)
        if style == .span { return elapsed < 60 ? String(localized: "刚刚") : Self.duration(elapsed) }
        if case .ago = self { return DateLabel.short(since, now: now, calendar: calendar) }
        if style == .list, elapsed < 60 {
            switch self {
            case .running: return String(localized: "刚开始")
            case .waiting: return String(localized: "刚刚")
            default: return String(localized: "刚发出")
            }
        }
        let duration = Self.duration(elapsed)
        return switch self {
        case .running: String(localized: "运行了 \(duration)")
        case .waiting: String(localized: "等了 \(duration)")
        default: String(localized: "\(duration)前发出")
        }
    }

    func live(_ style: Style) -> Live { Live(clock: self, style: style) }

    struct Live: DiscreteFormatStyle {
        let clock: SessionClock
        let style: Style

        func format(_ now: Date) -> String { clock.text(now: now, style: style) }

        func discreteInput(after now: Date) -> Date? { segment(around: now).next }

        func discreteInput(before now: Date) -> Date? { segment(around: now).start.addingTimeInterval(-0.001) }

        private func segment(around now: Date) -> (start: Date, next: Date) {
            let since = clock.since
            let elapsed = max(now.timeIntervalSince(since), 0)
            if style == .span {
                let step: TimeInterval = elapsed < 3600 ? 60 : elapsed < 86_400 ? 3600 : 86_400
                let next = since.tick(every: step, after: now)
                return (next.addingTimeInterval(-step), next)
            }
            if !clock.isRunningClock, elapsed >= 86_400 {
                let calendar = Calendar.current
                let midnight = calendar.startOfDay(for: now)
                return (midnight, calendar.date(byAdding: .day, value: 1, to: midnight) ?? now.addingTimeInterval(86_400))
            }
            let step: TimeInterval = elapsed < 60 && style == .header && clock.isRunningClock ? 1 : elapsed < 3600 ? 60 : 3600
            let next = since.tick(every: step, after: now)
            return (next.addingTimeInterval(-step), next)
        }
    }
}

nonisolated extension SessionClock {
    struct Elapsed: DiscreteFormatStyle {
        let since: Date

        private var clock: Live { SessionClock.running(since: since).live(.header) }

        func format(_ now: Date) -> String { SessionClock.duration(now.timeIntervalSince(since)) }

        func discreteInput(after now: Date) -> Date? { clock.discreteInput(after: now) }

        func discreteInput(before now: Date) -> Date? { clock.discreteInput(before: now) }
    }
}

nonisolated extension SessionClock {
    struct Waited: DiscreteFormatStyle {
        let since: Date

        private var minute: Date { since.addingTimeInterval(60) }
        private var elapsed: Elapsed { Elapsed(since: since) }

        func format(_ now: Date) -> String { now < minute ? String(localized: "刚刚") : String(localized: "已等 \(elapsed.format(now))") }

        func discreteInput(after now: Date) -> Date? { now < minute ? minute : elapsed.discreteInput(after: now) }

        func discreteInput(before now: Date) -> Date? { now <= minute ? nil : elapsed.discreteInput(before: now) }
    }
}

nonisolated extension Date {
    func tick(every step: TimeInterval, after now: Date) -> Date {
        var count = (now.timeIntervalSince(self) / step).rounded(.down) + 1
        while addingTimeInterval(count * step) <= now { count += 1 }
        return addingTimeInterval(count * step)
    }
}

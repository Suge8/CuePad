import CueStore
import Foundation

/// 给 Cue 看的在 Kit（`CueScheduleWords`）。
nonisolated enum ScheduleText {
    static func repeats(_ rule: CueRepeat) -> String {
        [cycle(rule.cycle), clock(hour: rule.hour, minute: rule.minute)].joined(separator: " ")
    }

    private static func cycle(_ cycle: CueRepeat.Cycle) -> String {
        switch cycle {
        case .daily: return String(localized: "每天")
        case .weekly(let days): return String(localized: "每\(weekdays(days))")
        case .monthly(let day): return String(localized: "每月 \(day) 号")
        }
    }

    private static func weekdays(_ days: Set<Int>) -> String {
        weekOrder.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and))
    }

    static func moment(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天 \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "明天 \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        return within(date, now: now) ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : date.formatted(.dateTime.month().day().hour().minute())
    }

    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天") }
        if calendar.isDateInTomorrow(date) { return String(localized: "明天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        return within(date, now: now) ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month().day())
    }

    private static func within(_ date: Date, now: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return (0..<7).contains(days)
    }

    static func time(_ line: CueMemoryLine) -> String {
        if let rule = line.repeats { return clock(hour: rule.hour, minute: rule.minute) }
        return line.remindAt?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    static func days(_ line: CueMemoryLine) -> String {
        if let rule = line.repeats { return cycle(rule.cycle) }
        return line.remindAt.map { day($0) } ?? ""
    }

    @MainActor static func when(_ draft: ScheduleDraft) -> (day: String, time: String) {
        let time = draft.date.formatted(date: .omitted, time: .shortened)
        return (draft.repeats.map { cycle($0.cycle) } ?? day(draft.date), time)
    }

    /// 只说事实，不猜原因。
    static func missed(_ last: CueScheduled.Last) -> String {
        String(localized: "\(moment(last.due)) 那次错过，\(last.at.formatted(date: .omitted, time: .shortened)) 补上")
    }

    static func clock(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]
}

import CueStore
import Foundation

/// 定时在界面上的说法（任务气泡、定时页、手机 Cue 面板、Cue 页的叫醒那一行同一套）；给 Cue 看的在 Kit（`CueScheduleWords`）。
nonisolated enum ScheduleText {
    /// 怎么重复："每天 8:00""每周一和周四 9:00""每月 1 号 9:00"；一次性的写"只这一次"。
    static func repeats(_ rule: CueRepeat?) -> String {
        guard let rule else { return String(localized: "只这一次") }
        let time = clock(hour: rule.hour, minute: rule.minute)
        switch rule.cycle {
        case .daily: return String(localized: "每天 \(time)")
        case .weekly(let days): return String(localized: "每\(weekdays(days)) \(time)")
        case .monthly(let day): return String(localized: "每月 \(day) 号 \(time)")
        }
    }

    /// 重复的哪几天："每天""每周一和周四""每月 1 号"。
    static func cycle(_ cycle: CueRepeat.Cycle) -> String {
        switch cycle {
        case .daily: return String(localized: "每天")
        case .weekly(let days): return String(localized: "每\(weekdays(days))")
        case .monthly(let day): return String(localized: "每月 \(day) 号")
        }
    }

    /// 一周里的哪几天："周一和周四"（周一在前）。
    private static func weekdays(_ days: Set<Int>) -> String {
        weekOrder.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and))
    }

    /// 一个时刻离现在多远的说法："今天 15:00""明天 8:00""周一 9:00"（一周之内）、"11月3日 9:00"。
    static func moment(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天 \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "明天 \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        return within(date, now: now) ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : date.formatted(.dateTime.month().day().hour().minute())
    }

    /// 哪天："今天""明天""昨天""周一"（一周之内）、"11月3日"。
    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天") }
        if calendar.isDateInTomorrow(date) { return String(localized: "明天") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        return within(date, now: now) ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month().day())
    }

    /// 在这一周之内（今天起往后 7 天）：写星期几，不写日期。
    private static func within(_ date: Date, now: Date) -> Bool {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        return (0..<7).contains(days)
    }

    /// 一条定时几点（重复的取规则里的时刻，一次的取那一次）。
    static func time(_ line: CueMemoryLine) -> String {
        if let rule = line.repeats { return clock(hour: rule.hour, minute: rule.minute) }
        return line.remindAt?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    /// 一条定时哪天：重复的写怎么重复（"每天"），一次的写那一天（"明天"）。
    static func days(_ line: CueMemoryLine) -> String {
        if let rule = line.repeats { return cycle(rule.cycle) }
        return line.remindAt.map { day($0) } ?? ""
    }

    /// 新定时那颗钮上写的哪天与几点：一次的"明天""9:00"，重复的"每天""9:00"。两段各自成字，不拼成一句。
    @MainActor static func when(_ draft: ScheduleDraft) -> (day: String, time: String) {
        let time = draft.date.formatted(date: .omitted, time: .shortened)
        return (draft.repeats.map { cycle($0.cycle) } ?? day(draft.date), time)
    }

    /// 错过后补上的那句事实："今天 9:00 那次错过，9:41 补上"。不猜原因。
    static func missed(_ last: CueScheduled.Last) -> String {
        String(localized: "\(moment(last.due)) 那次错过，\(last.at.formatted(date: .omitted, time: .shortened)) 补上")
    }

    /// 某天里的时刻（按这台设备的 12/24 小时制）。
    static func clock(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// 一周从周一排到周日（`Calendar` 的 weekday：1 是周日）。
    static let weekOrder = [2, 3, 4, 5, 6, 7, 1]
}

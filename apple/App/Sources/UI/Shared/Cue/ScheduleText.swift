import CueStore
import Foundation

/// 定时在界面上的说法（任务气泡、"记得什么"的定时一组、手机 Cue 面板、Cue 页的叫醒那一行同一套）；给 Cue 看的在 Kit（`CueScheduleWords`）。
nonisolated enum ScheduleText {
    /// 怎么重复："每天 8:00""每周一和周四 9:00""每月 1 号 9:00"；一次性的写"只这一次"。
    static func repeats(_ rule: CueRepeat?) -> String {
        guard let rule else { return String(localized: "只这一次") }
        let time = clock(hour: rule.hour, minute: rule.minute)
        switch rule.cycle {
        case .daily: return String(localized: "每天 \(time)")
        case .weekly(let days):
            let names = weekOrder.filter(days.contains).map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
            return String(localized: "每\(names.formatted(.list(type: .and))) \(time)")
        case .monthly(let day): return String(localized: "每月 \(day) 号 \(time)")
        }
    }

    /// 一个时刻离现在多远的说法："今天 15:00""明天 8:00""周一 9:00"（一周之内）、"11月3日 9:00"。
    static func moment(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current, time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今天 \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "明天 \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天 \(time)") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if (0..<7).contains(days) { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.month().day().hour().minute())
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

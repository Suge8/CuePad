import Foundation

nonisolated extension Calendar {
    /// 按周分组的地方都用它：一周总从周一算起，不随地区设置（时区仍用这个日历的）。会话历史的"本周"、灵感"更早"的按周分组同一条。
    var mondayFirst: Calendar {
        var calendar = self
        calendar.firstWeekday = 2
        return calendar
    }
}

/// 全 App 唯一的"什么时候"写法。会话的计时会随时间刷新（`SessionElapsed`）；灵感卡、回收站这些不加定时器，写的是打开时的值。
nonisolated enum DateLabel {
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < 60 { return String(localized: "刚刚") }
        if elapsed < 3600 { return relative(DateComponents(minute: -elapsed / 60), style: .abbreviated) }
        if elapsed < 86_400 { return relative(DateComponents(hour: -elapsed / 3600), style: .abbreviated) }
        return day(date, now: now, calendar: calendar)
    }

    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return relative(DateComponents(day: -1), style: .full)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(monthDay) }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    static let monthDay = Date.FormatStyle.dateTime.month(.defaultDigits).day()

    private static func relative(_ offset: DateComponents, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        // 系统的中文写法数字贴着单位（"33分钟前"），全 App 的时长都隔一格（"33 分钟"，`SessionClock.duration`）：这里补上那一格
        return formatter.localizedString(from: offset).replacing(/(\d)(\p{Han})/) { "\($0.1) \($0.2)" }
    }
}

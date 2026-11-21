import Foundation

nonisolated extension Calendar {
    var mondayFirst: Calendar {
        var calendar = self
        calendar.firstWeekday = 2
        return calendar
    }
}

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

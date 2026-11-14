import Foundation

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
        return formatter.localizedString(from: offset)
    }
}

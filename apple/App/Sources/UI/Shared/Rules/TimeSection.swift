import Foundation

nonisolated enum TimeSection: Sendable {
    case today, yesterday, thisWeek, thisMonth, earlier

    var title: String {
        switch self {
        case .today: String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .thisWeek: String(localized: "本周")
        case .thisMonth: String(localized: "本月")
        case .earlier: String(localized: "更早")
        }
    }

    static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> TimeSection {
        let date = min(date, now)
        let calendar = calendar.mondayFirst
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        return .earlier
    }

    struct Run<Item> {
        let section: TimeSection
        var items: [Item]
    }

    static func split<Item>(_ items: [Item], date: (Item) -> Date, now: Date, calendar: Calendar = .current) -> [Run<Item>] {
        var runs: [Run<Item>] = []
        for item in items {
            let section = of(date(item), now: now, calendar: calendar)
            if runs.last?.section == section { runs[runs.count - 1].items.append(item) } else { runs.append(Run(section: section, items: [item])) }
        }
        return runs
    }
}

extension TimeSection.Run: Sendable where Item: Sendable {}
extension TimeSection.Run: Equatable where Item: Equatable {}

import Foundation

/// 按时间分段：今天 / 昨天 / 本周 / 本月 / 更早。会话历史（已结束的会话按结束时间，进展页的会话段与 ⌘K）与 Cue 的记忆（按记下的时间）共用。
/// 会话历史按结束时间从新到旧分页；同一时间段只列一组。
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

    /// 昨天先于本周、本月判断：周一的昨天、月初的昨天都算昨天。一周总从周一算起，不随地区设置（时区仍用传入的日历）。
    /// 其他设备的时钟可能快于本机：未来时间按今天分组，不改原始时间或顺序。
    static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> TimeSection {
        let date = min(date, now)
        var calendar = calendar
        calendar.firstWeekday = 2
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

    /// 按从新到旧排好的条目分段；设备时钟不一致时，同一时间段可能在输入里不相邻。
    static func split<Item>(_ items: [Item], date: (Item) -> Date, now: Date, calendar: Calendar = .current) -> [Run<Item>] {
        var runs: [Run<Item>] = []
        for item in items {
            let section = of(date(item), now: now, calendar: calendar)
            if let index = runs.firstIndex(where: { $0.section == section }) {
                runs[index].items.append(item)
            } else {
                runs.append(Run(section: section, items: [item]))
            }
        }
        return runs
    }
}

extension TimeSection.Run: Sendable where Item: Sendable {}
extension TimeSection.Run: Equatable where Item: Equatable {}

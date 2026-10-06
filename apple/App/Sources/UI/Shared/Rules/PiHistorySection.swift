import Foundation

/// Pi 历史（已结束的会话）按结束时间分段：今天 / 昨天 / 本周 / 本月 / 更早。手机 Agent 页与 Mac ⌘K 的会话范围共用。
/// 查询按结束时间从新到旧分页，所以分段只在末尾增长，下一页不会插进上面的段。
nonisolated enum PiHistorySection: Int, CaseIterable, Sendable {
    case today, yesterday, thisWeek, thisMonth, earlier

    var title: String {
        switch self {
        case .today: "今天"
        case .yesterday: "昨天"
        case .thisWeek: "本周"
        case .thisMonth: "本月"
        case .earlier: "更早"
        }
    }

    /// 昨天先于本周、本月判断：周一的昨天、月初的昨天都算昨天。一周总从周一算起，不随地区设置（时区仍用传入的日历）。
    static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> PiHistorySection {
        var calendar = calendar
        calendar.firstWeekday = 2
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        return .earlier
    }

    struct Run<Item> {
        let section: PiHistorySection
        var items: [Item]
    }

    /// 按从新到旧排好的会话切成相连的段。
    static func split<Item>(_ items: [Item], date: (Item) -> Date, now: Date, calendar: Calendar = .current) -> [Run<Item>] {
        var runs: [Run<Item>] = []
        for item in items {
            let section = of(date(item), now: now, calendar: calendar)
            if runs.last?.section == section { runs[runs.count - 1].items.append(item) } else { runs.append(Run(section: section, items: [item])) }
        }
        return runs
    }
}

extension PiHistorySection.Run: Sendable where Item: Sendable {}
extension PiHistorySection.Run: Equatable where Item: Equatable {}

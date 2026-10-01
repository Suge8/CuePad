import Foundation

/// 排墙所需的卡片事实；由 `Card` 与该项目的最近发送时间得到。
nonisolated struct CardStamp: Equatable, Sendable {
    var id: UUID
    var modifiedAt: Date
    var lastSentAt: Date?
    var isPinned: Bool
}

/// 项目页的卡片分区：置顶单列、工作集卡片墙、更早。
///
/// 墙只在打开另一个项目或跨天时重排；同一次打开里，墙上的卡编辑后原地不动（保住"它在左上角"的空间记忆），
/// 排好之后新建或再次编辑的卡插到墙首，删除的卡离开；没有新编辑却新出现的卡按规则补到墙尾或进更早。
nonisolated struct WallArrangement: Equatable, Sendable {
    static let recentDays = 14.0
    static let unsentDays = 30.0
    /// 墙上最多几张（不含置顶）。
    static let capacity = 14

    var project: UUID?
    var arrangedAt: Date
    var pinned: [UUID]
    var wall: [UUID]
    var older: [UUID]

    static func arrange(_ cards: [CardStamp], project: UUID?, now: Date, calendar: Calendar) -> WallArrangement {
        let sorted = cards.sorted(by: newestFirst)
        let pinned = sorted.filter(\.isPinned)
        let candidates = sorted.filter { !$0.isPinned }
        let eligible = candidates.filter { onWall($0, now: now) }.prefix(capacity).map(\.id)
        let eligibleSet = Set(eligible)
        return WallArrangement(
            project: project, arrangedAt: now, pinned: pinned.map(\.id), wall: eligible,
            older: candidates.map(\.id).filter { !eligibleSet.contains($0) })
    }

    /// 卡片数据变化后的新分区：换项目或跨天时整体重排，否则保持已有位置。
    func refreshed(with cards: [CardStamp], project: UUID?, now: Date, calendar: Calendar) -> WallArrangement {
        guard project == self.project, calendar.isDate(now, inSameDayAs: arrangedAt) else {
            return Self.arrange(cards, project: project, now: now, calendar: calendar)
        }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let placed = Set(pinned + wall)
        let known = placed.union(older)
        let touched = cards.filter { $0.modifiedAt > arrangedAt && !placed.contains($0.id) }.sorted(by: Self.newestFirst)
        // 排墙之后才出现、却没有新编辑的卡（旧库导入、同步下来、别处移入）按上墙规则补到墙尾，不打乱已有位置
        let arrived = cards.filter { $0.modifiedAt <= arrangedAt && !known.contains($0.id) }.sorted(by: Self.newestFirst)

        let pinnedNow = touched.filter(\.isPinned).map(\.id) + pinned.filter { byID[$0]?.isPinned == true }
            + arrived.filter(\.isPinned).map(\.id)
        var wallNow = touched.filter { !$0.isPinned }.map(\.id) + wall.filter { byID[$0].map { !$0.isPinned } ?? false }
        let room = max(0, Self.capacity - wallNow.count)
        wallNow += arrived.filter { !$0.isPinned && Self.onWall($0, now: now) }.prefix(room).map(\.id)
        let kept = Set(pinnedNow + wallNow)
        let olderNow = cards.filter { !kept.contains($0.id) }.sorted(by: Self.newestFirst).map(\.id)
        return WallArrangement(project: project, arrangedAt: arrangedAt, pinned: pinnedNow, wall: wallNow, older: olderNow)
    }

    private static func onWall(_ card: CardStamp, now: Date) -> Bool {
        let age = now.timeIntervalSince(card.modifiedAt) / 86_400
        return age <= recentDays || (age <= unsentDays && card.lastSentAt == nil)
    }

    private static func newestFirst(_ a: CardStamp, _ b: CardStamp) -> Bool {
        a.modifiedAt != b.modifiedAt ? a.modifiedAt > b.modifiedAt : a.id.uuidString < b.id.uuidString
    }
}

/// "更早"列表的一组：三个月内按周（周首取日历设置），更久按月。
nonisolated struct OlderGroup: Equatable, Sendable {
    enum Period: Hashable, Sendable {
        case week(start: Date)
        case month(start: Date)
    }

    var period: Period
    var cards: [UUID]

    static let weeklyMonths = 3

    /// 要不要给各组加日期标题：只有一组按周的卡时不要（每行自带日期）；按月的组要标题来折叠，多组时要标题来分隔。
    static func needsTitles(in groups: [OlderGroup]) -> Bool {
        guard groups.count == 1, let only = groups.first else { return !groups.isEmpty }
        if case .month = only.period { return true }
        return false
    }

    /// 组与组内卡片都是新的在前。
    static func group(_ cards: [CardStamp], now: Date, calendar: Calendar) -> [OlderGroup] {
        let weeklySince = calendar.date(byAdding: .month, value: -weeklyMonths, to: now) ?? now
        var groups: [OlderGroup] = []
        for card in cards.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let period = period(of: card.modifiedAt, weekly: card.modifiedAt >= weeklySince, calendar: calendar)
            if groups.last?.period == period {
                groups[groups.count - 1].cards.append(card.id)
            } else {
                groups.append(OlderGroup(period: period, cards: [card.id]))
            }
        }
        return groups
    }

    private static func period(of date: Date, weekly: Bool, calendar: Calendar) -> Period {
        if weekly, let week = calendar.dateInterval(of: .weekOfYear, for: date) {
            return .week(start: week.start)
        }
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return .month(start: month)
    }
}

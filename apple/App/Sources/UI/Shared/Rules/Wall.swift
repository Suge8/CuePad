import Foundation

nonisolated struct CardStamp: Equatable, Sendable {
    var id: UUID
    var modifiedAt: Date
    var isPinned: Bool
}

nonisolated struct WallArrangement: Equatable, Sendable {
    static let recentDays = 30.0
    static let capacity = 14

    var project: UUID
    var arrangedAt: Date
    var pinned: [UUID]
    var wall: [UUID]
    var older: [UUID]

    static func arrange(_ cards: [CardStamp], project: UUID, now: Date) -> WallArrangement {
        let sorted = cards.sorted(by: newestFirst)
        let pinned = sorted.filter(\.isPinned)
        let candidates = sorted.filter { !$0.isPinned }
        let eligible = candidates.filter { onWall($0, now: now) }.prefix(capacity).map(\.id)
        let eligibleSet = Set(eligible)
        return WallArrangement(
            project: project, arrangedAt: now, pinned: pinned.map(\.id), wall: eligible,
            older: candidates.map(\.id).filter { !eligibleSet.contains($0) })
    }

    func refreshed(with cards: [CardStamp], project: UUID, now: Date, calendar: Calendar) -> WallArrangement {
        guard project == self.project, calendar.isDate(now, inSameDayAs: arrangedAt) else {
            return Self.arrange(cards, project: project, now: now)
        }
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let placed = Set(pinned + wall)
        let known = placed.union(older)
        let touched = cards.filter { $0.modifiedAt > arrangedAt && !placed.contains($0.id) }.sorted(by: Self.newestFirst)
        let arrived = cards.filter { $0.modifiedAt <= arrangedAt && !known.contains($0.id) }.sorted(by: Self.newestFirst)

        let wasPinned = Set(pinned)
        let pinnedNow = cards.filter { $0.isPinned && !wasPinned.contains($0.id) }.sorted(by: Self.newestFirst).map(\.id)
            + pinned.filter { byID[$0]?.isPinned == true }
        let unpinned = pinned.filter { byID[$0]?.isPinned == false }
        var wallNow = touched.filter { !$0.isPinned }.map(\.id) + unpinned + wall.filter { byID[$0].map { !$0.isPinned } ?? false }
        let room = max(0, Self.capacity - wallNow.count)
        wallNow += arrived.filter { !$0.isPinned && Self.onWall($0, now: now) }.prefix(room).map(\.id)
        let kept = Set(pinnedNow + wallNow)
        let olderNow = cards.filter { !kept.contains($0.id) }.sorted(by: Self.newestFirst).map(\.id)
        return WallArrangement(project: project, arrangedAt: arrangedAt, pinned: pinnedNow, wall: wallNow, older: olderNow)
    }

    private static func onWall(_ card: CardStamp, now: Date) -> Bool {
        let age = now.timeIntervalSince(card.modifiedAt) / 86_400
        return age <= recentDays
    }

    private static func newestFirst(_ a: CardStamp, _ b: CardStamp) -> Bool {
        a.modifiedAt != b.modifiedAt ? a.modifiedAt > b.modifiedAt : a.id.uuidString < b.id.uuidString
    }
}

nonisolated struct OlderGroup: Equatable, Sendable {
    enum Period: Hashable, Sendable {
        case all
        case week(start: Date)
        case sparseMonth(start: Date)
        case month(start: Date)
    }

    var period: Period
    var cards: [UUID]

    static let anchor = "older"
    static let weeklyMonths = 3
    static let fewLimit = 4

    static func needsTitles(in groups: [OlderGroup]) -> Bool {
        guard groups.count == 1, let only = groups.first else { return !groups.isEmpty }
        return only.isMonth
    }

    var isMonth: Bool { if case .month = period { true } else { false } }

    static func group(_ cards: [CardStamp], now: Date, calendar: Calendar) -> [OlderGroup] {
        let calendar = calendar.mondayFirst
        let sorted = cards.sorted(by: { $0.modifiedAt > $1.modifiedAt })
        if sorted.count <= fewLimit { return sorted.isEmpty ? [] : [OlderGroup(period: .all, cards: sorted.map(\.id))] }
        let weeklySince = calendar.date(byAdding: .month, value: -weeklyMonths, to: now) ?? now
        var groups: [OlderGroup] = []
        for card in sorted {
            let period = period(of: card.modifiedAt, weekly: card.modifiedAt >= weeklySince, calendar: calendar)
            if groups.last?.period == period {
                groups[groups.count - 1].cards.append(card.id)
            } else {
                groups.append(OlderGroup(period: period, cards: [card.id]))
            }
        }
        return mergingSparseMonths(groups, dates: Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.modifiedAt) }), calendar: calendar)
    }

    private static func mergingSparseMonths(_ groups: [OlderGroup], dates: [UUID: Date], calendar: Calendar) -> [OlderGroup] {
        var result: [OlderGroup] = []
        var run: [OlderGroup] = []
        var runMonth: Date?
        func flush() {
            guard !run.isEmpty else { return }
            if let runMonth, run.allSatisfy({ $0.cards.count == 1 }) {
                result.append(OlderGroup(period: .sparseMonth(start: runMonth), cards: run.flatMap(\.cards)))
            } else {
                result += run
            }
            run = []
        }
        for group in groups {
            guard case .week = group.period, let date = group.cards.first.flatMap({ dates[$0] }) else {
                flush()
                runMonth = nil
                result.append(group)
                continue
            }
            let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
            if month != runMonth { flush() }
            runMonth = month
            run.append(group)
        }
        flush()
        return result
    }

    private static func period(of date: Date, weekly: Bool, calendar: Calendar) -> Period {
        if weekly, let week = calendar.dateInterval(of: .weekOfYear, for: date) {
            return .week(start: week.start)
        }
        let month = calendar.dateInterval(of: .month, for: date)?.start ?? date
        return .month(start: month)
    }
}

extension OlderGroup.Period {
    func title(now: Date = .now, calendar: Calendar = .current) -> String {
        switch self {
        case .all:
            return String(localized: "更早")
        case .week(let start):
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(start.formatted(DateLabel.monthDay)) – \(end.formatted(DateLabel.monthDay))"
        case .sparseMonth(let start), .month(let start):
            let sameYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
            return start.formatted(sameYear ? Date.FormatStyle.dateTime.month(.abbreviated) : Date.FormatStyle.dateTime.year().month(.abbreviated))
        }
    }
}

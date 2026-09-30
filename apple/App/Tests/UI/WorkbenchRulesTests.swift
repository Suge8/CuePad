import Foundation
import Testing
@testable import CuePad

/// 项目页的纯规则：工作集卡片墙、"更早"分组、Pi 会话归项目。规格见 docs/development.md「视觉」。
struct WallTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    let project = UUID()
    /// 2026-09-30（周三）15:00，上海时间。
    let now = WallTests.date(2026, 9, 30, hour: 15)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func card(daysAgo: Double, sent: Bool = false, pinned: Bool = false, id: UUID = UUID()) -> CardStamp {
        let modified = now.addingTimeInterval(-daysAgo * 86_400)
        return CardStamp(id: id, modifiedAt: modified, lastSentAt: sent ? modified : nil, isPinned: pinned)
    }

    func arrange(_ cards: [CardStamp], at time: Date? = nil) -> WallArrangement {
        WallArrangement.arrange(cards, project: project, now: time ?? now, calendar: Self.calendar)
    }

    // MARK: 上墙

    @Test func 两周内编辑的上墙_一个月内编辑且从未发送的上墙_其余进更早() {
        let recentSent = card(daysAgo: 3, sent: true)
        let unsent = card(daysAgo: 20)
        let oldSent = card(daysAgo: 20, sent: true)
        let stale = card(daysAgo: 40)

        let wall = arrange([stale, oldSent, unsent, recentSent])

        #expect(wall.wall == [recentSent.id, unsent.id])
        #expect(wall.older == [oldSent.id, stale.id])
    }

    @Test func 墙按最近编辑排序且有名额_超出的进更早() {
        let cards = (0..<(WallArrangement.capacity + 2)).map { card(daysAgo: Double($0) * 0.5) }

        let wall = arrange(cards.shuffled())

        #expect(wall.wall == cards.prefix(WallArrangement.capacity).map(\.id))
        #expect(wall.older == cards.suffix(2).map(\.id))
    }

    @Test func 置顶卡单列_无论多旧都在_不占墙名额() {
        let pinnedOld = card(daysAgo: 200, pinned: true)
        let recent = (0..<WallArrangement.capacity).map { card(daysAgo: Double($0) * 0.5) }

        let wall = arrange(recent + [pinnedOld])

        #expect(wall.pinned == [pinnedOld.id])
        #expect(wall.wall == recent.map(\.id))
        #expect(wall.older.isEmpty)
    }

    // MARK: 同一次打开里墙不自己挪动

    @Test func 同一天编辑墙上的卡_墙的顺序不变() {
        let a = card(daysAgo: 1), b = card(daysAgo: 2)
        let first = arrange([a, b])
        let later = now.addingTimeInterval(3600)
        let edited = CardStamp(id: b.id, modifiedAt: later, lastSentAt: nil, isPinned: false)

        let next = first.refreshed(with: [a, edited], project: project, now: later, calendar: Self.calendar)

        #expect(next.wall == [a.id, b.id])
    }

    @Test func 再次编辑的旧卡与新建的卡_回到墙首_最近的在最前() {
        let a = card(daysAgo: 1), old = card(daysAgo: 60)
        let first = arrange([a, old])
        let t1 = now.addingTimeInterval(600), t2 = now.addingTimeInterval(1200)
        let reedited = CardStamp(id: old.id, modifiedAt: t1, lastSentAt: nil, isPinned: false)
        let fresh = CardStamp(id: UUID(), modifiedAt: t2, lastSentAt: nil, isPinned: false)

        let next = first.refreshed(with: [a, reedited, fresh], project: project, now: t2, calendar: Self.calendar)

        #expect(next.wall == [fresh.id, old.id, a.id])
        #expect(next.older.isEmpty)
    }

    @Test func 删除的卡离开墙_其余顺序不变() {
        let a = card(daysAgo: 1), b = card(daysAgo: 2), c = card(daysAgo: 3)
        let first = arrange([a, b, c])

        let next = first.refreshed(with: [a, c], project: project, now: now, calendar: Self.calendar)

        #expect(next.wall == [a.id, c.id])
    }

    @Test func 打开另一个项目或跨天才重排() {
        let a = card(daysAgo: 1), b = card(daysAgo: 2)
        let first = arrange([a, b])
        let later = now.addingTimeInterval(1800)
        let edited = CardStamp(id: b.id, modifiedAt: later, lastSentAt: nil, isPinned: false)

        let otherProject = first.refreshed(with: [a, edited], project: UUID(), now: later, calendar: Self.calendar)
        let nextDay = first.refreshed(
            with: [a, edited], project: project, now: Self.date(2026, 10, 1, hour: 9), calendar: Self.calendar)

        #expect(otherProject.wall == [b.id, a.id])
        #expect(nextDay.wall == [b.id, a.id])
    }

    // MARK: 更早

    @Test func 更早三个月内按周分组_更久按月分组_新的在前() {
        let thisWeekOld = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 9, 1), lastSentAt: nil, isPinned: false)  // 周二
        let sameWeek = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 31), lastSentAt: nil, isPinned: false)  // 周一
        let previousWeek = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 8, 30), lastSentAt: nil, isPinned: false)  // 周日
        let may = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 5, 20), lastSentAt: nil, isPinned: false)
        let mayEarly = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 5, 2), lastSentAt: nil, isPinned: false)
        let april = CardStamp(id: UUID(), modifiedAt: Self.date(2026, 4, 9), lastSentAt: nil, isPinned: false)

        let groups = OlderGroup.group(
            [april, sameWeek, may, previousWeek, mayEarly, thisWeekOld], now: now, calendar: Self.calendar)

        #expect(groups == [
            OlderGroup(period: .week(start: Self.date(2026, 8, 31, hour: 0)), cards: [thisWeekOld.id, sameWeek.id]),
            OlderGroup(period: .week(start: Self.date(2026, 8, 24, hour: 0)), cards: [previousWeek.id]),
            OlderGroup(period: .month(start: Self.date(2026, 5, 1, hour: 0)), cards: [may.id, mayEarly.id]),
            OlderGroup(period: .month(start: Self.date(2026, 4, 1, hour: 0)), cards: [april.id]),
        ])
    }
}

struct PiProjectMatchTests {
    let proj = UUID(), outer = UUID(), project = UUID()
    var directories: [UUID: String] { [proj: "/a/proj", outer: "/a", project: "/a/project/"] }

    @Test(arguments: [
        ("/a/proj", "proj"),
        ("/a/proj/src/ui", "proj"),
        ("/a/project", "project"),
        ("/a/project/x", "project"),
        ("/a/other", "outer"),
        ("/b/proj", "none"),
    ])
    func 会话按工作目录分段匹配_最深的目录优先(cwd: String, expected: String) {
        let names = [proj: "proj", outer: "outer", project: "project"]
        let matched = PiProjectMatch.project(forDirectory: cwd, in: directories)
        #expect(matched.map { names[$0]! } ?? "none" == expected)
    }
}

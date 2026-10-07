import Foundation
import Testing
@testable import CuePad

/// 回归：墙排好之后才出现、但没有新编辑的卡（首次启动时后台导入旧库、同步下来）不能一律落进"更早"。
struct WallArrivalTests {
    @Test func 排墙后导入的旧卡按上墙规则补到墙尾_已有位置不动() {
        let calendar = WallTests.calendar
        let now = WallTests.date(2026, 9, 30, hour: 15)
        let project = UUID()
        let existing = CardStamp(id: UUID(), modifiedAt: now.addingTimeInterval(-3_600), lastSentAt: nil, isPinned: false)
        let first = WallArrangement.arrange([existing], project: project, now: now, calendar: calendar)
        let importedRecent = CardStamp(id: UUID(), modifiedAt: now.addingTimeInterval(-2 * 86_400), lastSentAt: nil, isPinned: false)
        let importedStale = CardStamp(id: UUID(), modifiedAt: now.addingTimeInterval(-90 * 86_400), lastSentAt: nil, isPinned: false)
        let importedPinned = CardStamp(id: UUID(), modifiedAt: now.addingTimeInterval(-90 * 86_400), lastSentAt: nil, isPinned: true)

        let next = first.refreshed(
            with: [existing, importedRecent, importedStale, importedPinned], project: project,
            now: now.addingTimeInterval(60), calendar: calendar)

        #expect(next.wall == [existing.id, importedRecent.id])
        #expect(next.pinned == [importedPinned.id])
        #expect(next.older == [importedStale.id])
    }

    /// 回归：设为资料（或不再是资料）不改正文、修改时间不变，也要当场进出"资料"一组，不能掉进"更早"。
    @Test func 设为资料或取消_当场进出资料一组() {
        let calendar = WallTests.calendar
        let now = WallTests.date(2026, 9, 30, hour: 15)
        let project = UUID()
        let card = CardStamp(id: UUID(), modifiedAt: now.addingTimeInterval(-3_600), lastSentAt: nil, isPinned: false)
        let first = WallArrangement.arrange([card], project: project, now: now, calendar: calendar)

        var marked = card
        marked.isPinned = true
        let pinned = first.refreshed(with: [marked], project: project, now: now.addingTimeInterval(60), calendar: calendar)
        #expect(pinned.pinned == [card.id] && pinned.wall.isEmpty && pinned.older.isEmpty)

        let unpinned = pinned.refreshed(with: [card], project: project, now: now.addingTimeInterval(120), calendar: calendar)
        #expect(unpinned.pinned.isEmpty && unpinned.wall == [card.id])
    }
}

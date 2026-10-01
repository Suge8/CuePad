import Foundation
import Testing
@testable import CuePad

/// 卡片墙的分列：已有的卡不因为新增或删除而换列（记住的位置不作废），只在列数变化时重新分配。
struct WallColumnsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    /// 每张卡的高度：a 100、b 300、c 100、d 100，新卡 e 50。
    func height(_ id: UUID) -> Double {
        [a: 100, b: 300, c: 100, d: 100, e: 50][id] ?? 100
    }

    @Test func 初次排布按顺序放进当前最矮的一列() {
        let wall = WallColumns(order: [a, b, c, d], count: 2, height: height)

        #expect(wall.columns == [[a, c, d], [b]])
    }

    @Test func 新卡进最矮的一列的顶部_已有的卡不换列() {
        var wall = WallColumns(order: [a, b, c, d], count: 2, height: height)

        wall.update(order: [e, a, b, c, d], count: 2, height: height)

        // 两列高 300 与 300：并列时取左边一列
        #expect(wall.columns == [[e, a, c, d], [b]])
    }

    @Test func 删掉的卡离开_其余不换列() {
        var wall = WallColumns(order: [a, b, c, d], count: 2, height: height)

        wall.update(order: [a, c, d], count: 2, height: height)

        #expect(wall.columns == [[a, c, d], []])
    }

    @Test func 列数变了才重新分配() {
        var wall = WallColumns(order: [a, b, c, d], count: 2, height: height)

        wall.update(order: [a, b, c, d], count: 3, height: height)

        #expect(wall.columns == [[a, d], [b], [c]])
    }

    @Test func 跨天重新排墙时按新顺序整体重新分配() {
        let today = Date(timeIntervalSince1970: 0), tomorrow = Date(timeIntervalSince1970: 86_400)
        var wall = WallColumns(order: [a, b, c, d], count: 2, height: height, arrangedAt: today)

        wall.update(order: [d, c, b, a], count: 2, height: height, arrangedAt: tomorrow)

        #expect(wall.columns == WallColumns(order: [d, c, b, a], count: 2, height: height).columns)
    }
}

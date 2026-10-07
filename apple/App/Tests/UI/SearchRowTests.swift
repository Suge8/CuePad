#if os(iOS)
import Foundation
import Testing
@testable import CuePad

/// 灵感页与 Agent 页顶上那一排：往下滑时搜索框藏起（两侧圆钮留着），往上滑或回到顶上出现；正在搜时不藏。
@MainActor
struct SearchRowTests {
    @Test func 往下滑藏起_往上滑或回到顶上出现_正在搜时不藏() {
        #expect(SearchRow.hidesSearch(false, from: 200, to: 230, searching: false))
        #expect(SearchRow.hidesSearch(true, from: 230, to: 260, searching: false))
        #expect(!SearchRow.hidesSearch(true, from: 260, to: 250, searching: false))
        #expect(SearchRow.hidesSearch(true, from: 260, to: 260, searching: false))
        // 顶上一小段内不藏：刚开始滑、下拉回弹
        #expect(!SearchRow.hidesSearch(false, from: 0, to: 10, searching: false))
        #expect(!SearchRow.hidesSearch(true, from: 40, to: 0, searching: false))
        #expect(!SearchRow.hidesSearch(false, from: 200, to: 400, searching: true))
    }
}
#endif

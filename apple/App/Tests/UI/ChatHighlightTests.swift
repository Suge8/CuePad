import Foundation
import Testing
@testable import CuePad

struct ChatHighlightTests {
    /// 在刻度滑条上连着跳两条：第二条的高亮不能被前一条的计时清掉，且各自到点淡去。
    @Test func 连着跳两条_第二条的高亮留着直到它自己的时间到() async {
        let highlight = ChatHighlight()
        let first = UUID(), second = UUID()

        highlight.flash(first, for: .seconds(30))
        highlight.flash(second, for: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(highlight.id == second)

        await eventually { highlight.id == nil }
    }
}

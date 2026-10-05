#if canImport(AppKit)
import AppKit
import CueText
import Testing
@testable import CueEditor

@MainActor
@Suite("选区")
struct SelectionTests {
    @Test("选中文字时给出选中部分的存储格式（分割线照原样），并报告有没有选区；没选中为 nil")
    func selectedStored() {
        let h = EditorHarness()
        h.load("甲乙丙\n---split---\n丁戊")  // 运行时：0 甲 1 乙 2 丙 3 换行 4 分割线 5 换行 6 丁 7 戊
        var reports: [Bool] = []
        h.textView.onSelectionChange = { reports.append($0) }

        h.textView.setSelectedRange(NSRange(location: 1, length: 6))
        #expect(h.textView.selectedStoredText == "乙丙\n---split---\n丁")
        h.setCaret(2)
        #expect(h.textView.selectedStoredText == nil)
        #expect(reports == [true, false])
    }
}
#endif

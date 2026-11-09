#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

@MainActor
private func markedRange(_ h: EditorHarness) -> NSRange? {
    guard let range = h.textView.markedTextRange else { return nil }
    let start = h.textView.offset(from: h.textView.beginningOfDocument, to: range.start)
    return NSRange(location: start, length: h.textView.offset(from: range.start, to: range.end))
}

@MainActor
@Suite("iOS 变量高亮与输入法组合")
struct IOSVariableHighlightTests {
    @Test("输入法组合期间：标记文本不被打断，不向外上报，提交后上报一次")
    func composing() {
        let h = EditorHarness()
        h.load("前 {{}} 后")
        h.setCaret(4)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }

        h.textView.setMarkedText("ming", selectedRange: NSRange(location: 4, length: 0))
        #expect(markedRange(h) == NSRange(location: 4, length: 4))
        #expect(highlightedRanges(in: h.textView, color: h.textView.theme.variableBackground) == [NSRange(location: 2, length: 8)])

        h.textView.setMarkedText("名字", selectedRange: NSRange(location: 2, length: 0))
        #expect(markedRange(h) == NSRange(location: 4, length: 2))

        h.textView.unmarkText()
        #expect(markedRange(h) == nil)
        #expect(h.stored == "前 {{名字}} 后")
        #expect(notified == ["前 {{名字}} 后"])
    }

}
#endif

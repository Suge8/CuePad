#if canImport(AppKit)
import AppKit
import Testing
@testable import CueEditor

@MainActor
@Suite("变量高亮与输入法组合")
struct VariableHighlightTests {
    private let nowhere = NSRange(location: NSNotFound, length: 0)

    @Test("变量高亮在加载与逐字输入时跟着 {{…}} 的范围走")
    func highlightFollowsVariables() {
        let h = EditorHarness()
        func highlighted() -> [NSRange] { highlightedRanges(in: h.textView, color: h.textView.theme.variableBackground) }
        h.load("前 {{已有}} 尾")
        #expect(highlighted() == [NSRange(location: 2, length: 6)])

        h.load("")
        for ch in "写{{变量}}好{{a" { h.textView.insertText(String(ch), replacementRange: nowhere) }
        #expect(highlighted() == [NSRange(location: 1, length: 6)])
        h.textView.insertText("}}", replacementRange: nowhere)
        #expect(highlighted() == [NSRange(location: 1, length: 6), NSRange(location: 8, length: 5)])
    }

    @Test("输入法组合期间：标记文本不被打断，提交后上报一次")
    func composing() {
        let h = EditorHarness()
        h.load("前 {{}} 后")
        h.setCaret(4)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }

        h.textView.setMarkedText("ming", selectedRange: NSRange(location: 4, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 4, length: 4))

        h.textView.setMarkedText("名字", selectedRange: NSRange(location: 2, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 4, length: 2))

        h.textView.insertText("名字", replacementRange: nowhere)
        #expect(!h.textView.hasMarkedText())
        #expect(h.stored == "前 {{名字}} 后")
        #expect(notified == ["前 {{名字}} 后"])  // 组合中不上报，提交后上报一次
    }

}

#endif

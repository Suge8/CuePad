#if canImport(AppKit)
import AppKit
import Testing
@testable import CueEditor

private func font(_ p: NSAttributedString, at index: Int = 0) -> NSFont? {
    p.attribute(.font, at: index, effectiveRange: nil) as? NSFont
}

@MainActor
@Suite("轻装饰")
struct DecorationTests {
    private let theme = CueEditorTheme.test
    private let nowhere = NSRange(location: NSNotFound, length: 0)

    @Test("第一行和别的行一样是正文；写 # 的行才是标题，随输入换字体")
    func firstLineIsBody() {
        let h = EditorHarness()
        h.load("先复现\n# 小节")
        var p = h.displayed()
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.headingFont)

        h.setCaret(0)
        h.textView.insertText("# ", replacementRange: nowhere)
        p = h.displayed()
        #expect(font(p[0]) == theme.headingFont && h.stored == "# 先复现\n# 小节")
    }

    @Test("增删围栏后，远处未被编辑的段落随之切换代码/正文")
    func fenceToggleRestylesDownstream() {
        let h = EditorHarness()
        h.load("p\nq\n```\nr")
        #expect(font(h.displayed()[3]) == theme.codeFont)

        h.setCaret(2)
        h.textView.insertText("```\n", replacementRange: nowhere)  // p ``` q ``` r：q 变代码，r 变正文
        let p = h.displayed()
        #expect(font(p[2]) == theme.codeFont)
        #expect(font(p[4]) == theme.font)
    }

    @Test("装饰不写入文本存储、不进撤销栈、不改存储格式")
    func storageUntouched() {
        let h = EditorHarness()
        let stored = "## 小节\n- 项\n```\nx\n```\n`c` {{v}}"
        h.load(stored)
        _ = h.displayed()
        #expect(h.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == theme.font)
        #expect(h.textView.undoManager?.canUndo == false)
        #expect(h.stored == stored)

        h.setCaret(h.textView.textStorage!.length)
        h.textView.insertText("y", replacementRange: nowhere)
        h.textView.undoManager?.undo()
        #expect(h.stored == stored)
        #expect(h.textView.undoManager?.canUndo == false)
    }

}

#endif

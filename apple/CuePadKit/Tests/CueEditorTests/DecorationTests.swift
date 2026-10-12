#if canImport(AppKit)
import AppKit
import CueText
import Testing
@testable import CueEditor

/// 编辑器在屏幕上实际展示的各段落（TextKit 布局出来的文本元素，带展示属性）。
@MainActor
private func displayed(_ h: EditorHarness) -> [NSAttributedString] {
    var paragraphs: [NSAttributedString] = []
    h.textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
        if let paragraph = fragment.textElement as? NSTextParagraph { paragraphs.append(paragraph.attributedString) }
        return true
    }
    return paragraphs
}

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
        var p = displayed(h)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.headingFont)

        h.setCaret(0)
        h.textView.insertText("# ", replacementRange: nowhere)
        p = displayed(h)
        #expect(font(p[0]) == theme.headingFont && h.stored == "# 先复现\n# 小节")
    }

    @Test("增删围栏后，远处未被编辑的段落随之切换代码/正文")
    func fenceToggleRestylesDownstream() {
        let h = EditorHarness()
        h.load("p\nq\n```\nr")
        #expect(font(displayed(h)[3]) == theme.codeFont)

        h.setCaret(2)
        h.textView.insertText("```\n", replacementRange: nowhere)  // p ``` q ``` r：q 变代码，r 变正文
        let p = displayed(h)
        #expect(font(p[2]) == theme.codeFont)
        #expect(font(p[4]) == theme.font)
    }

    @Test("装饰不写入文本存储、不进撤销栈、不改存储格式")
    func storageUntouched() {
        let h = EditorHarness()
        let stored = "## 小节\n- 项\n```\nx\n```\n`c` {{v}}"
        h.load(stored)
        _ = displayed(h)
        #expect(h.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == theme.font)
        #expect(h.textView.undoManager?.canUndo == false)
        #expect(h.stored == stored)

        h.setCaret(h.textView.textStorage!.length)
        h.textView.insertText("y", replacementRange: nowhere)
        h.textView.undoManager?.undo()
        #expect(h.stored == stored)
        #expect(h.textView.undoManager?.canUndo == false)
    }

    @Test("与输入法组合共存：标记文本不被打断，各行样式不变")
    func withComposing() {
        let h = EditorHarness()
        h.load("\n# 次行")
        h.setCaret(0)

        h.textView.setMarkedText("shou", selectedRange: NSRange(location: 4, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 0, length: 4))
        var p = displayed(h)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.headingFont)

        h.textView.insertText("首", replacementRange: nowhere)
        #expect(!h.textView.hasMarkedText())
        #expect(h.stored == "首\n# 次行")
        p = displayed(h)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.headingFont)
        #expect(h.textView.textLayoutManager != nil)
    }
}

#endif

#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

private func font(_ p: NSAttributedString, at index: Int = 0) -> UIFont? {
    p.attribute(.font, at: index, effectiveRange: nil) as? UIFont
}

private func color(_ p: NSAttributedString, at index: Int = 0) -> UIColor? {
    p.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
}

/// 至少要有 n 个段落，否则测试失败（而不是下标越界崩掉整个测试进程）。
@MainActor
private func paragraphs(_ h: EditorHarness, _ n: Int) throws -> [NSAttributedString] {
    let p = h.displayed()
    try #require(p.count >= n, "只排出了 \(p.count) 个段落")
    return p
}

@MainActor
private func markedRange(_ h: EditorHarness) -> NSRange? {
    guard let range = h.textView.markedTextRange else { return nil }
    let start = h.textView.offset(from: h.textView.beginningOfDocument, to: range.start)
    return NSRange(location: start, length: h.textView.offset(from: range.start, to: range.end))
}

@MainActor
@Suite("iOS 变量高亮")
struct IOSHighlightTests {
    private func background(_ h: EditorHarness) -> [NSRange] {
        highlightedRanges(in: h.textView, color: h.textView.theme.variableBackground)
    }

    @Test("加载与逐字输入时高亮精确跟随变量范围，且不写入文本存储属性")
    func tracksVariables() {
        let h = EditorHarness()
        h.load("前 {{已有}} 尾")
        #expect(background(h) == [NSRange(location: 2, length: 6)])

        h.load("")
        for ch in "写{{变量}}好{{a" { h.textView.insertText(String(ch)) }
        #expect(background(h) == [NSRange(location: 1, length: 6)])
        h.textView.insertText("}}")
        #expect(background(h) == [NSRange(location: 1, length: 6), NSRange(location: 8, length: 5)])

        let storage = h.textView.textStorage
        var painted = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { painted = true } }
        #expect(!painted)
    }

    @Test("输入法组合期间：标记文本不被打断，高亮实时更新，不向外上报，提交后上报一次")
    func composing() {
        let h = EditorHarness()
        h.load("前 {{}} 后")
        h.setCaret(4)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }

        h.textView.setMarkedText("ming", selectedRange: NSRange(location: 4, length: 0))
        #expect(markedRange(h) == NSRange(location: 4, length: 4))
        #expect(background(h) == [NSRange(location: 2, length: 8)])

        h.textView.setMarkedText("名字", selectedRange: NSRange(location: 2, length: 0))
        #expect(markedRange(h) == NSRange(location: 4, length: 2))
        #expect(background(h) == [NSRange(location: 2, length: 6)])

        h.textView.unmarkText()
        #expect(markedRange(h) == nil)
        #expect(h.stored == "前 {{名字}} 后")
        #expect(notified == ["前 {{名字}} 后"])
        #expect(background(h) == [NSRange(location: 2, length: 6)])
        #expect(h.textView.textLayoutManager != nil)
    }

}

@MainActor
@Suite("iOS 轻装饰")
struct IOSDecorationTests {
    private let theme = CueEditorTheme.test

    @Test("首个标题行用标题字体，其余用正文字体；标题随编辑移动")
    func title() throws {
        let h = EditorHarness()
        h.load("\n---split---\n周报\n正文")
        var p = try paragraphs(h, 4)
        #expect(font(p[2]) == theme.titleFont && font(p[3]) == theme.font && font(p[1]) == theme.font)

        h.load("\n第二行")
        h.setCaret(0)
        h.textView.insertText("首")
        p = try paragraphs(h, 2)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)
        h.textView.deleteBackward()
        p = try paragraphs(h, 2)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.titleFont)
    }

    @Test("围栏及内部整段用代码字体；增删围栏后远处未编辑的段落随之切换")
    func codeBlock() throws {
        let h = EditorHarness()
        h.load("标题\n```swift\n# 不是标题\nlet x = 1\n```\n正文")
        var p = try paragraphs(h, 6)
        #expect([1, 2, 3, 4].allSatisfy { font(p[$0]) == theme.codeFont } && font(p[5]) == theme.font)
        #expect(color(p[1], at: 0) == theme.markerColor)

        h.load("p\nq\n```\nr")
        #expect(font(try paragraphs(h, 4)[3]) == theme.codeFont)
        h.setCaret(2)
        h.textView.insertText("```\n")
        p = try paragraphs(h, 5)
        #expect(font(p[2]) == theme.codeFont && font(p[4]) == theme.font)
    }

    @Test("装饰不写入文本存储、不进撤销栈、不改存储格式")
    func storageUntouched() {
        let h = EditorHarness()
        let stored = "## 小节\n- 项\n```\nx\n```\n`c` {{v}}"
        h.load(stored)
        _ = h.displayed()
        #expect(h.textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == theme.font)
        #expect(h.textView.undoManager?.canUndo == false)
        #expect(h.stored == stored)
    }

    @Test("组合输入中标题易主，标记文本不被打断")
    func withComposing() throws {
        let h = EditorHarness()
        h.load("\n次行")
        h.setCaret(0)
        h.textView.setMarkedText("shou", selectedRange: NSRange(location: 4, length: 0))
        #expect(markedRange(h) == NSRange(location: 0, length: 4))
        var p = try paragraphs(h, 2)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)
        h.textView.setMarkedText("首", selectedRange: NSRange(location: 1, length: 0))
        h.textView.unmarkText()
        #expect(h.stored == "首\n次行")
        p = try paragraphs(h, 2)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)
    }

    @Test("动态字体：系统字号档位变化后，各角色的字体跟着放大")
    func dynamicType() async throws {
        let h = EditorHarness()
        h.load("标题\n正文")
        let before = try paragraphs(h, 2).map { font($0)?.pointSize ?? 0 }
        h.textView.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        #expect(await h.wait { (font(h.displayed().last ?? NSAttributedString())?.pointSize ?? 0) > before[1] * 1.5 })
        #expect((font(try paragraphs(h, 2)[0])?.pointSize ?? 0) > before[0] * 1.3)
    }
}
#endif

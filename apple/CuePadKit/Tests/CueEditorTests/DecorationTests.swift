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

private func color(_ p: NSAttributedString, at index: Int = 0) -> NSColor? {
    p.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
}

@MainActor
@Suite("轻装饰")
struct DecorationTests {
    private let theme = CueEditorTheme.neutral
    private let nowhere = NSRange(location: NSNotFound, length: 0)

    @Test("中文正文默认苹方")
    func pingFangByDefault() {
        let h = EditorHarness()
        h.load("标题\n正文")
        #expect(displayed(h).allSatisfy { font($0)?.fontName.hasPrefix("PingFangSC") == true })
    }

    @Test("首个非空、非分隔线的行用标题字体，其余用正文字体")
    func title() {
        let h = EditorHarness()
        h.load("\n---split---\n周报\n正文")
        let p = displayed(h)
        #expect(p.count == 4)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.font)
        #expect(font(p[2]) == theme.titleFont)
        #expect(font(p[3]) == theme.font)
    }

    @Test("标题随编辑移动：新标题换字体，未被编辑的旧标题恢复正文字体")
    func titleMoves() {
        let h = EditorHarness()
        h.load("\n第二行")
        #expect(font(displayed(h)[1]) == theme.titleFont)

        h.setCaret(0)
        h.textView.insertText("首", replacementRange: nowhere)
        var p = displayed(h)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)

        h.textView.deleteBackward(nil)
        p = displayed(h)
        #expect(font(p[0]) == theme.font && font(p[1]) == theme.titleFont)
    }

    @Test("## 标题行用标题字体，# 标记降低存在感，正文颜色不变")
    func headings() {
        let h = EditorHarness()
        h.load("标题\n## 小节\n正文")
        let heading = displayed(h)[1]
        #expect(font(heading, at: 3) == theme.headingFont)
        #expect(color(heading, at: 0) == theme.markerColor && color(heading, at: 1) == theme.markerColor)
        #expect(color(heading, at: 3) == theme.textColor)
    }

    @Test("列表标记降低存在感，折行悬挂缩进；普通行折行不缩进")
    func lists() throws {
        let h = EditorHarness(width: 320)
        let long = String(repeating: "很长的一条内容", count: 12)
        h.load("标题\n- \(long)\n  1. 序号\n\(long)")
        let p = displayed(h)
        #expect(color(p[1], at: 0) == theme.markerColor && color(p[1], at: 2) == theme.textColor)
        #expect(color(p[2], at: 2) == theme.markerColor && color(p[2], at: 5) == theme.textColor)

        func secondLineIndent(_ index: Int) throws -> CGFloat {
            var indent: CGFloat?
            var seen = 0
            h.textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                defer { seen += 1 }
                guard seen == index else { return true }
                let lines = fragment.textLineFragments
                if lines.count >= 2 { indent = lines[1].typographicBounds.minX - lines[0].typographicBounds.minX }
                return false
            }
            return try #require(indent)
        }
        #expect(try secondLineIndent(1) > 4)
        #expect(try secondLineIndent(3) == 0)
    }

    @Test("围栏及其内部整段用代码字体、不再识别标题；围栏字符降低存在感")
    func codeBlock() {
        let h = EditorHarness()
        h.load("标题\n```swift\n# 不是标题\nlet x = 1\n```\n正文")
        let p = displayed(h)
        #expect([1, 2, 3, 4].allSatisfy { font(p[$0]) == theme.codeFont })
        #expect(font(p[5]) == theme.font)
        #expect(color(p[1], at: 0) == theme.markerColor && color(p[4], at: 0) == theme.markerColor)
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

    @Test("行内 code 用代码字体与底色，反引号降低存在感；围栏内不重复处理")
    func inlineCode() {
        let h = EditorHarness()
        h.load("标题\n运行 `swift test` 后")
        let p = displayed(h)[1]
        #expect(font(p, at: 0) == theme.font)
        #expect(font(p, at: 4) == theme.codeFont)
        #expect(p.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil)
        #expect(color(p, at: 3) == theme.markerColor)
        #expect(p.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test("代码块整行铺底色，直到行宽末尾")
    func codeBandSpansLine() throws {
        let h = EditorHarness()
        h.load("标题\n```\nx\n```\n正文")
        var codeLine: CGRect?
        var bodyLine: CGRect?
        let origin = h.textView.textContainerOrigin
        h.textView.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString.string
            if text == "x\n" { codeLine = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y) }
            if text == "正文" { bodyLine = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y) }
            return true
        }
        let code = try #require(codeLine), body = try #require(bodyLine)
        func pixel(_ line: CGRect) throws -> NSColor {
            try #require(h.renderedCenterColor(of: CGRect(x: 600, y: line.minY + 2, width: 4, height: 4)))
        }
        let codePixel = try pixel(code), bodyPixel = try pixel(body)
        #expect(abs(codePixel.brightnessComponent - bodyPixel.brightnessComponent) > 0.02)
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

    @Test("与变量高亮共存：标题行里的变量照常高亮")
    func withVariables() {
        let h = EditorHarness()
        h.load("标题\n## {{名}} 节")
        #expect(font(displayed(h)[1], at: 4) == theme.headingFont)
        #expect(highlightedRanges(in: h.textView, color: theme.variableBackground) == [NSRange(location: 6, length: 5)])
    }

    @Test("与输入法组合共存：组合中标题易主，标记文本不被打断")
    func withComposing() {
        let h = EditorHarness()
        h.load("\n次行")
        h.setCaret(0)

        h.textView.setMarkedText("shou", selectedRange: NSRange(location: 4, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 0, length: 4))
        var p = displayed(h)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)

        h.textView.insertText("首", replacementRange: nowhere)
        #expect(!h.textView.hasMarkedText())
        #expect(h.stored == "首\n次行")
        p = displayed(h)
        #expect(font(p[0]) == theme.titleFont && font(p[1]) == theme.font)
        #expect(h.textView.textLayoutManager != nil)
    }

    @Test("换主题后装饰使用新字体")
    func themeChange() {
        let h = EditorHarness()
        h.load("标题\n正文")
        var next = theme
        next.titleFont = .boldSystemFont(ofSize: 30)
        h.textView.theme = next
        #expect(font(displayed(h)[0]) == next.titleFont)
    }
}

#endif

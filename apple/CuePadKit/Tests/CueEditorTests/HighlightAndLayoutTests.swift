import AppKit
import CueText
import Testing
@testable import CueEditor

@MainActor
@Suite("变量高亮")
struct HighlightTests {
    private func background(_ h: EditorHarness) -> [NSRange] {
        highlightedRanges(in: h.textView, color: h.textView.theme.variableBackground)
    }
    private let nowhere = NSRange(location: NSNotFound, length: 0)

    @Test("加载与逐字输入时高亮精确跟随变量范围，且不写入文本存储属性")
    func tracksVariables() {
        let h = EditorHarness()
        h.load("前 {{已有}} 尾")
        #expect(background(h) == [NSRange(location: 2, length: 6)])

        h.load("")
        for ch in "写{{变量}}好{{a" { h.textView.insertText(String(ch), replacementRange: nowhere) }
        #expect(background(h) == [NSRange(location: 1, length: 6)])
        h.textView.insertText("}}", replacementRange: nowhere)
        #expect(background(h) == [NSRange(location: 1, length: 6), NSRange(location: 8, length: 5)])

        let storage = h.textView.textStorage!
        var painted = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { painted = true } }
        #expect(!painted)
    }

    @Test("输入法组合期间：标记文本不被打断，变量高亮随组合内容实时更新")
    func composing() {
        let h = EditorHarness()
        h.load("前 {{}} 后")
        h.setCaret(4)
        var notified: [String] = []
        h.textView.onChange = { notified.append($0) }

        h.textView.setMarkedText("ming", selectedRange: NSRange(location: 4, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 4, length: 4))
        #expect(background(h) == [NSRange(location: 2, length: 8)])

        h.textView.setMarkedText("名字", selectedRange: NSRange(location: 2, length: 0), replacementRange: nowhere)
        #expect(h.textView.hasMarkedText() && h.textView.markedRange() == NSRange(location: 4, length: 2))
        #expect(background(h) == [NSRange(location: 2, length: 6)])

        h.textView.insertText("名字", replacementRange: nowhere)
        #expect(!h.textView.hasMarkedText())
        #expect(h.stored == "前 {{名字}} 后")
        #expect(notified == ["前 {{名字}} 后"])  // 组合中不上报，提交后上报一次
        #expect(background(h) == [NSRange(location: 2, length: 6)])
        #expect(h.textView.textLayoutManager != nil)  // 全程没有降级到 TextKit 1
    }

    @Test("换主题后高亮使用新颜色")
    func themeChange() {
        let h = EditorHarness()
        h.load("{{甲}}")
        var theme = h.textView.theme
        theme.variableBackground = NSColor.systemYellow
        h.textView.theme = theme
        #expect(highlightedRanges(in: h.textView, color: .systemYellow) == [NSRange(location: 0, length: 5)])
    }
}

@MainActor
@Suite("布局")
struct LayoutTests {
    @Test("长文档的总高度在加载完成后即稳定，滚动不再让滚动条跳变")
    func heightStable() async throws {
        let h = EditorHarness(height: 640)
        var stored = ""
        let line = String(repeating: "这是一段用来测试排版的中文文字，", count: 8)
        for i in 0..<400 {
            stored += line + "\n"
            if i % 40 == 39 { stored += "![](cuepad://img/\(try h.store.store(makePNG(width: 1600, height: 1000, seed: i))))\n" }
        }
        h.load(stored)
        // 高度稳定 = 半秒内不再变化（布局是分片推进的，每片间隔远小于此）
        var last = -1.0, stableCount = 0
        #expect(await h.wait(timeout: 15) {
            let current = Double(h.textView.frame.height)
            stableCount = current == last ? stableCount + 1 : 0
            last = current
            return stableCount >= 25
        })
        let settled = h.textView.frame.height

        let clip = h.editor.contentView
        var y: CGFloat = 0
        while y < h.textView.frame.height {
            clip.scroll(to: NSPoint(x: 0, y: y))
            h.editor.reflectScrolledClipView(clip)
            h.layout()
            y += 400
        }
        let afterScroll = h.textView.frame.height
        #expect(abs(afterScroll - settled) / afterScroll < 0.02)
    }
}

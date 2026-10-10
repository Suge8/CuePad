#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

@MainActor
@Suite("iOS 分割线")
struct IOSDividerTests {
    private let split = CueFormat.splitMarker

    @Test("工具栏插入分割线：光标前内容在线上、光标后在线下，光标落到线下一行；可撤销")
    func insertDivider() {
        let h = EditorHarness()
        h.load("第一段内容第二段内容")
        h.setCaret(5)
        h.textView.insertDivider()
        #expect(h.stored == "第一段内容\n\(split)\n第二段内容")
        #expect(h.caret == 8)
        h.textView.undoManager?.undo()
        #expect(h.stored == "第一段内容第二段内容")
    }

    @Test("读屏：分割线读作\"分割线\"，图片仍是占位字符；文字和选区位置不受影响")
    func spokenValue() throws {
        let h = EditorHarness()
        let id = try h.store.store(makePNG(width: 20, height: 20))
        h.load("甲\n\(split)\n乙\n![](cuepad://img/\(id))")
        #expect(h.textView.accessibilityValue == "甲\n分割线\n乙\n\u{FFFC}")
        #expect(h.stored == "甲\n\(split)\n乙\n![](cuepad://img/\(id))")
    }

    @Test("分割线真的画在页面上，主题换了颜色跟着换")
    func rendersTheLine() async throws {
        let h = EditorHarness()
        h.load("第一段内容\n\(split)\n第二段内容")
        let frame = try #require(h.imageLineFrames().first)
        #expect(await h.wait { h.rendered(frame, contains: h.textView.theme.dividerColor) })

        var next = h.textView.theme
        next.dividerColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        h.textView.theme = next
        #expect(await h.wait { h.rendered(frame, contains: next.dividerColor) })
        #expect(!h.rendered(frame, contains: CueEditorTheme.test.dividerColor))
    }

    @Test("光标整体跨过分割线：程序设置选区时也不会落在分割线行上")
    func caretCrossing() throws {
        let h = EditorHarness()
        h.load("第一段内容\n\(split)\n\n第二段内容")  // 运行时：0…5 首行，6 分割线，8 空行
        h.setCaret(5)
        h.textView.selectedRange = NSRange(location: 6, length: 0)
        #expect(h.caret == 8)
        h.textView.selectedRange = NSRange(location: 7, length: 0)
        #expect(h.caret == 5)

        let end = try #require(h.textView.position(from: h.textView.beginningOfDocument, offset: 6))
        h.textView.selectedTextRange = h.textView.textRange(from: end, to: end)
        #expect(h.caret == 8)
    }

    @Test("分割线下一行行首 Backspace 整条删掉分割线，可撤销")
    func merge() {
        let h = EditorHarness()
        let doc = "甲\n\(split)\n乙"
        h.load(doc)
        h.setCaret(4)
        h.textView.deleteBackward()
        #expect(h.stored == "甲\n乙")
        h.textView.undoManager?.undo()
        #expect(h.stored == doc)
    }

    @Test("选区跨过分割线时可整体删除")
    func deleteAcross() {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙丁")
        h.textView.selectedRange = NSRange(location: 1, length: 5)
        h.textView.deleteBackward()
        #expect(h.stored == "甲丁")
    }

}
#endif

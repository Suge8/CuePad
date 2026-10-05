#if canImport(AppKit)
import AppKit
import CueText
import Testing
@testable import CueEditor

@MainActor
@Suite("分割线")
struct DividerTests {
    private let split = CueFormat.splitMarker

    @Test("工具栏插入分割线：光标前内容在线上、光标后在线下，光标落到线下一行")
    func insertDivider() {
        let h = EditorHarness()
        h.load("第一段内容第二段内容")
        h.setCaret(5)
        h.textView.insertDivider()
        #expect(h.stored == "第一段内容\n\(split)\n第二段内容")
        #expect(h.caret == 8)
    }

    @Test("光标整体跨过分割线：左右、上下都不会落在分割线行上")
    func caretCrossing() {
        let h = EditorHarness()
        h.load("第一段内容\n\(split)\n\n第二段内容")  // 运行时：0…5 首行，6 分割线，8 空行，9 起第二段
        h.setCaret(5)
        h.textView.moveRight(nil)
        #expect(h.caret == 8)
        h.textView.moveLeft(nil)
        #expect(h.caret == 5)

        h.setCaret(2)
        var visited: [Int] = []
        for _ in 0..<4 { h.textView.moveDown(nil); visited.append(h.caret) }
        #expect(!visited.contains(6) && !visited.contains(7))
        #expect(visited.first == 8)

        h.setCaret(7)
        #expect(h.caret != 6 && h.caret != 7)
    }

    @Test("分割线前后的 Backspace / Delete 整条删掉分割线，可撤销")
    func merge() {
        let h = EditorHarness()
        let doc = "甲\n\(split)\n乙"
        h.load(doc)
        h.textView.undoManager?.removeAllActions()
        h.setCaret(4)
        h.textView.deleteBackward(nil)
        #expect(h.stored == "甲\n乙")
        h.textView.undoManager?.undo()
        #expect(h.stored == doc)

        h.textView.undoManager?.removeAllActions()
        h.setCaret(1)
        h.textView.deleteForward(nil)
        #expect(h.stored == "甲\n乙")
    }

    @Test("选区跨过分割线时可整体删除")
    func deleteAcross() {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙丁")
        h.textView.setSelectedRange(NSRange(location: 1, length: 5))
        h.textView.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.stored == "甲丁")
    }
}
#endif

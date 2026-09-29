#if canImport(AppKit)
import AppKit
import CueText
import Testing
@testable import CueEditor

@MainActor
@Suite("分块")
struct BlockTests {
    private let split = CueFormat.splitMarker

    @Test("Shift+Enter 在光标处切块，光标落到新块；组合输入期间不触发")
    func shiftEnter() {
        let h = EditorHarness()
        h.load("第一块内容第二块内容")
        h.setCaret(5)
        h.textView.keyDown(with: h.keyEvent("\r", keyCode: 36, modifiers: .shift))
        #expect(h.stored == "第一块内容\n\(split)\n第二块内容")
        #expect(h.caret == 8)  // 分隔线行之后的新块行首

        let composing = EditorHarness()
        composing.load("甲")
        composing.setCaret(1)
        composing.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.textView.keyDown(with: composing.keyEvent("\r", keyCode: 36, modifiers: .shift))
        #expect(!composing.stored.contains(split))
    }

    @Test("光标整体跨过分隔线：左右、上下都不会落在分隔线行上")
    func caretCrossing() {
        let h = EditorHarness()
        h.load("第一块内容\n\(split)\n\n第二块内容")  // 运行时：0…5 首行，6 分隔线，8 空行，9 起第二块
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

    @Test("块首 Backspace / 块尾 Delete 整条合并分隔线，可撤销")
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

    @Test("选区跨过分隔线时可整体删除")
    func deleteAcross() {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙丁")
        h.textView.setSelectedRange(NSRange(location: 1, length: 5))
        h.textView.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(h.stored == "甲丁")
    }

    @Test("分隔线的复制/发送按钮把其后一块的正文交给外部")
    func dividerButtons() throws {
        let h = EditorHarness()
        h.load("首块\n\(split)\n第二块\n第二块尾\n\(split)\n第三块")
        var actions: [CueBlockAction] = []
        h.textView.onBlockAction = { actions.append($0) }
        let dividers = h.subviews(of: CueDividerView.self)
        try #require(dividers.count == 2)
        func button(_ title: String, in divider: CueDividerView) throws -> NSButton {
            try #require(divider.subviews.compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        try button("复制", in: dividers[0]).performClick(nil)
        try button("发送", in: dividers[1]).performClick(nil)
        #expect(actions == [
            CueBlockAction(kind: .copy, blockIndex: 1, text: "第二块\n第二块尾"),
            CueBlockAction(kind: .send, blockIndex: 2, text: "第三块"),
        ])
    }

    @Test("Cmd+Shift+C 复制光标所在块；Cmd+↓/↑ 跳块")
    func blockShortcuts() {
        let h = EditorHarness()
        h.load("甲块\n\(split)\n乙块\n乙块尾\n\(split)\n丙块")
        var actions: [CueBlockAction] = []
        h.textView.onBlockAction = { actions.append($0) }
        h.setCaret(7)
        #expect(h.textView.performKeyEquivalent(with: h.keyEvent("C", keyCode: 8, modifiers: [.command, .shift])))
        #expect(actions == [CueBlockAction(kind: .copy, blockIndex: 1, text: "乙块\n乙块尾")])

        h.setCaret(1)
        h.textView.moveToEndOfDocument(nil)
        #expect(h.caret == 5)  // 下一块首行
        h.textView.moveToBeginningOfDocument(nil)
        #expect(h.caret == 0)
    }

    @Test("分隔线标签按所选编号样式随块序号更新，无编号时不显示")
    func numberingLabels() {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙")
        /// 按文档中的先后顺序取各分隔线的标签。
        func labels() -> [String] {
            h.subviews(of: CueDividerView.self)
                .sorted { $0.convert(NSPoint.zero, to: h.textView).y < $1.convert(NSPoint.zero, to: h.textView).y }
                .map(\.labelText)
        }
        #expect(labels() == [""])

        h.textView.numbering = .decimal
        h.layout()
        #expect(labels() == ["2"])
        h.textView.numbering = .cjk
        h.layout()
        #expect(labels() == ["二"])

        h.setCaret(1)
        h.textView.insertSplit()
        h.layout()
        #expect(labels() == ["二", "三"])

        h.textView.numbering = .none
        h.layout()
        #expect(labels() == ["", ""])
    }
}

#endif

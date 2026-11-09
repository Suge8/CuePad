#if canImport(AppKit)
import AppKit
import Testing
@testable import CueEditor

@MainActor
@Suite("轻装饰")
struct DecorationTests {
    private let nowhere = NSRange(location: NSNotFound, length: 0)

    @Test("装饰不进撤销栈：键入后撤销回到加载时的原文")
    func decorationStaysOutOfUndo() {
        let h = EditorHarness()
        let stored = "## 小节\n- 项\n```\nx\n```\n`c` {{v}}"
        h.load(stored)
        #expect(h.textView.undoManager?.canUndo == false)

        h.setCaret(h.textView.textStorage!.length)
        h.textView.insertText("y", replacementRange: nowhere)
        h.textView.undoManager?.undo()
        #expect(h.stored == stored)
        #expect(h.textView.undoManager?.canUndo == false)
    }
}

#endif

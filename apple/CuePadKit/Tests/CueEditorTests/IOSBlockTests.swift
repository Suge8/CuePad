#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

@MainActor
private func command(_ h: EditorHarness, input: String, flags: UIKeyModifierFlags) -> UIKeyCommand? {
    h.textView.keyCommands?.first { $0.input == input && $0.modifierFlags == flags }
}

@MainActor
private func run(_ command: UIKeyCommand?, on h: EditorHarness) {
    guard let command else { return }
    h.textView.perform(command.action, with: command)
}

@MainActor
@Suite("iOS 分块")
struct IOSBlockTests {
    private let split = CueFormat.splitMarker

    @Test("Shift+Enter（硬件键盘）在光标处切块；组合输入期间不触发")
    func shiftEnter() throws {
        let h = EditorHarness()
        h.load("第一块内容第二块内容")
        h.setCaret(5)
        let key = try #require(command(h, input: "\r", flags: .shift))
        #expect(key.wantsPriorityOverSystemBehavior)
        run(key, on: h)
        #expect(h.stored == "第一块内容\n\(split)\n第二块内容")
        #expect(h.caret == 8)

        let composing = EditorHarness()
        composing.load("甲")
        composing.setCaret(1)
        composing.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        run(command(composing, input: "\r", flags: .shift), on: composing)
        #expect(!composing.stored.contains(split))
    }

    @Test("光标整体跨过分隔线：程序设置选区时也不会落在分隔线行上")
    func caretCrossing() throws {
        let h = EditorHarness()
        h.load("第一块内容\n\(split)\n\n第二块内容")  // 运行时：0…5 首行，6 分隔线，8 空行
        h.setCaret(5)
        h.textView.selectedRange = NSRange(location: 6, length: 0)
        #expect(h.caret == 8)
        h.textView.selectedRange = NSRange(location: 7, length: 0)
        #expect(h.caret == 5)

        let end = try #require(h.textView.position(from: h.textView.beginningOfDocument, offset: 6))
        h.textView.selectedTextRange = h.textView.textRange(from: end, to: end)
        #expect(h.caret == 8)
    }

    @Test("块首 Backspace 整条合并分隔线，可撤销")
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

    @Test("选区跨过分隔线时可整体删除")
    func deleteAcross() {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙丁")
        h.textView.selectedRange = NSRange(location: 1, length: 5)
        h.textView.deleteBackward()
        #expect(h.stored == "甲丁")
    }

    @Test("分隔线的复制/发送按钮把其后一块的正文交给外部")
    func dividerButtons() async throws {
        let h = EditorHarness()
        h.load("首块\n\(split)\n第二块\n第二块尾\n\(split)\n第三块")
        var actions: [CueBlockAction] = []
        h.textView.onBlockAction = { actions.append($0) }
        #expect(await h.wait { h.subviews(of: CueDividerView.self).count == 2 })
        try #require(h.subviews(of: CueDividerView.self).count == 2)
        let dividers = h.subviews(of: CueDividerView.self).sorted { $0.convert(CGPoint.zero, to: h.textView).y < $1.convert(CGPoint.zero, to: h.textView).y }
        func button(_ label: String, in divider: CueDividerView) throws -> UIButton {
            try #require(divider.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel?.hasPrefix(label) == true })
        }
        try button("复制", in: dividers[0]).sendActions(for: .primaryActionTriggered)
        try button("发送", in: dividers[1]).sendActions(for: .primaryActionTriggered)
        #expect(actions == [
            CueBlockAction(kind: .copy, blockIndex: 1, text: "第二块\n第二块尾"),
            CueBlockAction(kind: .send, blockIndex: 2, text: "第三块"),
        ])
    }

    @Test("⌘⇧C 复制光标所在块；⌘↓/⌘↑ 跳块，无块可跳时回落到文档尾/首")
    func blockShortcuts() throws {
        let h = EditorHarness()
        h.load("甲块\n\(split)\n乙块\n乙块尾\n\(split)\n丙块")
        var actions: [CueBlockAction] = []
        h.textView.onBlockAction = { actions.append($0) }
        h.setCaret(7)
        run(command(h, input: "c", flags: [.command, .shift]), on: h)
        #expect(actions == [CueBlockAction(kind: .copy, blockIndex: 1, text: "乙块\n乙块尾")])

        h.setCaret(1)
        run(command(h, input: UIKeyCommand.inputDownArrow, flags: .command), on: h)
        #expect(h.caret == 5)
        run(command(h, input: UIKeyCommand.inputUpArrow, flags: .command), on: h)
        #expect(h.caret == 0)

        h.setCaret(h.textView.textStorage.length)
        run(command(h, input: UIKeyCommand.inputDownArrow, flags: .command), on: h)
        #expect(h.caret == h.textView.textStorage.length)  // 末块：无块可跳，回落到文档尾
        run(command(h, input: UIKeyCommand.inputUpArrow, flags: .command), on: h)
        #expect(h.caret == 5)  // 末块只有一行，光标已在块首行：直接到上一块块首
        run(command(h, input: UIKeyCommand.inputUpArrow, flags: .command), on: h)
        #expect(h.caret == 0)
        run(command(h, input: UIKeyCommand.inputUpArrow, flags: .command), on: h)
        #expect(h.caret == 0)  // 首块块首：无块可跳，回落到文档首
    }

    @Test("分隔线标签按所选编号样式随块序号更新，无编号时不显示")
    func numberingLabels() async {
        let h = EditorHarness()
        h.load("甲乙\n\(split)\n丙")
        func labels() -> [String] {
            h.subviews(of: CueDividerView.self)
                .sorted { $0.convert(CGPoint.zero, to: h.textView).y < $1.convert(CGPoint.zero, to: h.textView).y }
                .map(\.labelText)
        }
        #expect(await h.wait { labels() == [""] })

        h.textView.numbering = .decimal
        h.layout()
        #expect(labels() == ["2"])
        h.textView.numbering = .cjk
        h.layout()
        #expect(labels() == ["二"])

        h.setCaret(1)
        h.textView.insertSplit()
        h.layout()
        #expect(await h.wait { labels() == ["二", "三"] })

        h.textView.numbering = .none
        h.layout()
        #expect(labels() == ["", ""])
    }
}
#endif

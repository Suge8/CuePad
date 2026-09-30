#if canImport(AppKit)
import AppKit
import CueText

extension CueTextView {
    private static let returnKeyCode: UInt16 = 36

    /// 在光标处切块（Shift+Enter；iOS 宿主的工具栏按钮同样调用它）。
    public func insertSplit() {
        apply(core.buffer().splitEdit(selection: selectedRange()))
    }

    private func apply(_ edit: CueEdit) {
        let insertion = core.insertion(for: edit)
        guard shouldChangeText(in: edit.range, replacementString: insertion.string) else { return }
        textStorage!.replaceCharacters(in: edit.range, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: edit.caret, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.returnKeyCode, event.modifierFlags.contains(.shift), !hasMarkedText() {
            insertSplit()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return super.performKeyEquivalent(with: event)
        }
        core.performBlockAction(.copy, blockIndex: core.buffer().blockIndex(at: selectedRange().location))
        return true
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let edit = core.buffer().mergeBackward(selection: selectedRange()) { apply(edit) } else { super.deleteBackward(sender) }
    }

    public override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(), let edit = core.buffer().mergeForward(selection: selectedRange()) { apply(edit) } else { super.deleteForward(sender) }
    }

    /// Cmd+↑/↓：先跳块，无块可跳时回落到文档首尾。
    public override func moveToBeginningOfDocument(_ sender: Any?) {
        if let target = core.buffer().prevBlockStart(from: selectedRange().location) { jump(to: target) } else { super.moveToBeginningOfDocument(sender) }
    }

    public override func moveToEndOfDocument(_ sender: Any?) {
        if let target = core.buffer().nextBlockStart(from: selectedRange().location) { jump(to: target) } else { super.moveToEndOfDocument(sender) }
    }

    private func jump(to location: Int) {
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// 空光标不落在分隔线行上：所有选区变化（键盘、鼠标、程序）都经这里规范化。
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0, textStorage!.length > 0 else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        let caret = core.buffer().normalizedCaret(from: selectedRange().location, to: range.location)
        super.setSelectedRanges([NSValue(range: NSRange(location: caret, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
    }
}
#endif

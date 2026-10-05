#if canImport(AppKit)
import AppKit
import CueText

extension CueTextView {
    /// 在光标处插入一条分割线（外部工具栏的按钮调用）。
    public func insertDivider() {
        apply(core.buffer().dividerEdit(selection: selectedRange()))
    }

    private func apply(_ edit: CueEdit) {
        let insertion = core.insertion(for: edit)
        guard shouldChangeText(in: edit.range, replacementString: insertion.string) else { return }
        textStorage!.replaceCharacters(in: edit.range, with: insertion)
        didChangeText()
        setSelectedRange(NSRange(location: edit.caret, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let edit = core.buffer().mergeBackward(selection: selectedRange()) { apply(edit) } else { super.deleteBackward(sender) }
    }

    public override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(), let edit = core.buffer().mergeForward(selection: selectedRange()) { apply(edit) } else { super.deleteForward(sender) }
    }

    /// 所有选区变化（键盘、鼠标、程序）都经这里：空光标不落在分割线行上；有没有选区变了就报告。
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        defer { reportSelection() }
        guard ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0, textStorage!.length > 0 else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        let caret = core.buffer().normalizedCaret(from: selectedRange().location, to: range.location)
        super.setSelectedRanges([NSValue(range: NSRange(location: caret, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
    }

    private func reportSelection() {
        let selecting = selectedRange().length > 0
        guard selecting != reportedSelection else { return }
        reportedSelection = selecting
        onSelectionChange?(selecting)
    }
}
#endif

#if canImport(UIKit)
import CueText
import UIKit

extension CueTextView {
    /// 在光标处切块（硬件键盘 Shift+Enter 与键盘工具栏的"分块"共用）。
    public func insertSplit() {
        apply(core.buffer().splitEdit(selection: selectedRange))
    }

    private func apply(_ edit: CueEdit) {
        replace(edit.range, with: core.insertion(for: edit), caret: edit.caret)
    }

    /// 所有程序性编辑的唯一入口：替换文本、放置光标、登记撤销（UITextView 不会为直接改 storage 登记撤销）、
    /// 并像用户编辑一样发出 `textDidChange`。
    func replace(_ range: NSRange, with replacement: NSAttributedString, caret: Int) {
        let previous = textStorage.attributedSubstring(from: range)
        let previousCaret = selectedRange.location
        let inserted = NSRange(location: range.location, length: replacement.length)
        undoManager?.registerUndo(withTarget: self) { target in
            target.replace(inserted, with: previous, caret: previousCaret)
        }
        textStorage.replaceCharacters(in: range, with: replacement)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = core.baseAttributes
        scrollRangeToVisible(selectedRange)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: self)
        delegate?.textViewDidChange?(self)
    }

    // MARK: 键盘

    /// 块首 Backspace 整条合并分隔线；其它情况走系统默认删除。
    public override func deleteBackward() {
        if markedTextRange == nil, let edit = core.buffer().mergeBackward(selection: selectedRange) { apply(edit) } else { super.deleteBackward() }
    }

    /// 硬件键盘前向删除：块尾按下时整条合并分隔线，返回 true 表示已处理；其它位置交还系统默认。
    func handleForwardDelete() -> Bool {
        guard markedTextRange == nil, let edit = core.buffer().mergeForward(selection: selectedRange) else { return false }
        apply(edit)
        return true
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardDeleteForward }), handleForwardDelete() { return }
        super.pressesBegan(presses, with: event)
    }

    public override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "分块", action: #selector(splitCommand), input: "\r", modifierFlags: .shift),
            UIKeyCommand(title: "上一块", action: #selector(previousBlockCommand), input: UIKeyCommand.inputUpArrow, modifierFlags: .command),
            UIKeyCommand(title: "下一块", action: #selector(nextBlockCommand), input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
            UIKeyCommand(title: "复制本块", action: #selector(copyBlockCommand), input: "c", modifierFlags: [.command, .shift]),
        ]
        // 不加优先级，系统会先把 Shift+Enter 当换行、⌘↑/↓ 当跳文首尾
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return (super.keyCommands ?? []) + commands
    }

    @objc private func splitCommand(_ sender: UIKeyCommand) {
        guard markedTextRange == nil else { return }
        insertSplit()
    }

    /// ⌘↑/↓：先跳块，无块可跳时回落到文档首尾。
    @objc private func previousBlockCommand(_ sender: UIKeyCommand) {
        jump(to: core.buffer().prevBlockStart(from: selectedRange.location) ?? 0)
    }

    @objc private func nextBlockCommand(_ sender: UIKeyCommand) {
        jump(to: core.buffer().nextBlockStart(from: selectedRange.location) ?? textStorage.length)
    }

    @objc private func copyBlockCommand(_ sender: UIKeyCommand) {
        core.performBlockAction(.copy, blockIndex: core.buffer().blockIndex(at: selectedRange.location))
    }

    private func jump(to location: Int) {
        selectedRange = NSRange(location: location, length: 0)
        scrollRangeToVisible(selectedRange)
    }

    // MARK: 光标

    /// 空光标不落在分隔线行上：程序与键盘导致的选区变化都经这两个入口规范化。
    public override var selectedRange: NSRange {
        get { super.selectedRange }
        set { super.selectedRange = normalized(newValue) }
    }

    public override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            guard let newValue, newValue.isEmpty, textStorage.length > 0 else {
                super.selectedTextRange = newValue
                return
            }
            let target = offset(from: beginningOfDocument, to: newValue.start)
            let caret = normalized(NSRange(location: target, length: 0)).location
            guard caret != target, let position = position(from: beginningOfDocument, offset: caret) else {
                super.selectedTextRange = newValue
                return
            }
            super.selectedTextRange = textRange(from: position, to: position)
        }
    }

    private func normalized(_ range: NSRange) -> NSRange {
        guard range.length == 0, textStorage.length > 0 else { return range }
        let caret = core.buffer().normalizedCaret(from: super.selectedRange.location, to: range.location)
        return NSRange(location: caret, length: 0)
    }
}
#endif

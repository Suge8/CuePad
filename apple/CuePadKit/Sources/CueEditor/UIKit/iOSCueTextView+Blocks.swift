#if canImport(UIKit)
import CueText
import UIKit

extension CueTextView {
    func buffer() -> CueBuffer {
        let storage = textStorage
        return CueBuffer(text: storage.mutableString) { index in
            index < storage.length && storage.attribute(.attachment, at: index, effectiveRange: nil) is CueDividerAttachment
        }
    }

    /// 在光标处切块（硬件键盘 Shift+Enter 与键盘工具栏的"分块"共用）。
    public func insertSplit() {
        apply(buffer().splitEdit(selection: selectedRange))
    }

    private func apply(_ edit: CueEdit) {
        let insertion = NSMutableAttributedString()
        for (index, part) in edit.insert.components(separatedBy: String(UnicodeScalar(CueFormat.objectCharacter)!)).enumerated() {
            if index > 0 { insertion.append(dividerString()) }
            insertion.append(NSAttributedString(string: part, attributes: baseAttributes))
        }
        replace(edit.range, with: insertion, caret: edit.caret)
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
        typingAttributes = baseAttributes
        scrollRangeToVisible(selectedRange)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: self)
        delegate?.textViewDidChange?(self)
    }

    // MARK: 键盘

    /// 块首 Backspace 整条合并分隔线；其它情况走系统默认删除。
    public override func deleteBackward() {
        if markedTextRange == nil, let edit = buffer().mergeBackward(selection: selectedRange) { apply(edit) } else { super.deleteBackward() }
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
        jump(to: buffer().prevBlockStart(from: selectedRange.location) ?? 0)
    }

    @objc private func nextBlockCommand(_ sender: UIKeyCommand) {
        jump(to: buffer().nextBlockStart(from: selectedRange.location) ?? textStorage.length)
    }

    @objc private func copyBlockCommand(_ sender: UIKeyCommand) {
        performBlockAction(.copy, blockIndex: buffer().blockIndex(at: selectedRange.location))
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
        let caret = buffer().normalizedCaret(from: super.selectedRange.location, to: range.location)
        return NSRange(location: caret, length: 0)
    }

    // MARK: 块动作与编号

    func performDividerAction(_ kind: CueBlockActionKind, from attachment: CueDividerAttachment) {
        guard let location = dividerLocation(of: attachment),
              let divider = buffer().dividers().first(where: { $0.location == location }) else { return }
        performBlockAction(kind, blockIndex: divider.blockIndex)
    }

    private func performBlockAction(_ kind: CueBlockActionKind, blockIndex: Int) {
        let segments = CueSegments.parse(storedText)
        guard segments.indices.contains(blockIndex) else { return }
        onBlockAction?(CueBlockAction(kind: kind, blockIndex: blockIndex, text: segments[blockIndex].text))
    }

    private func dividerLocation(of attachment: CueDividerAttachment) -> Int? {
        var found: Int?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if value as? CueDividerAttachment === attachment { found = range.location; stop.pointee = true }
        }
        return found
    }

    func refreshDividerLabels() {
        if numbering != .none {
            for divider in buffer().dividers() {
                let attachment = textStorage.attribute(.attachment, at: divider.location, effectiveRange: nil) as? CueDividerAttachment
                setLabel(numbering.label(forSegment: divider.sequence), on: attachment)
            }
            return
        }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, _, _ in
            setLabel("", on: value as? CueDividerAttachment)
        }
    }

    private func setLabel(_ label: String, on attachment: CueDividerAttachment?) {
        guard let attachment, attachment.label != label else { return }
        attachment.label = label
        attachment.view?.labelText = label
    }
}
#endif

#if canImport(AppKit)
import AppKit
import CueText

extension CueTextView {
    private static let returnKeyCode: UInt16 = 36

    func buffer() -> CueBuffer {
        let storage = textStorage!
        return CueBuffer(text: storage.mutableString) { index in
            index < storage.length && storage.attribute(.attachment, at: index, effectiveRange: nil) is CueDividerAttachment
        }
    }

    /// 在光标处切块（Shift+Enter；iOS 宿主的工具栏按钮同样调用它）。
    public func insertSplit() {
        apply(buffer().splitEdit(selection: selectedRange()))
    }

    private func apply(_ edit: CueEdit) {
        let insertion = NSMutableAttributedString()
        for (index, part) in edit.insert.components(separatedBy: String(UnicodeScalar(CueFormat.objectCharacter)!)).enumerated() {
            if index > 0 { insertion.append(dividerString()) }
            insertion.append(NSAttributedString(string: part, attributes: baseAttributes))
        }
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
        performBlockAction(.copy, blockIndex: buffer().blockIndex(at: selectedRange().location))
        return true
    }

    public override func deleteBackward(_ sender: Any?) {
        if !hasMarkedText(), let edit = buffer().mergeBackward(selection: selectedRange()) { apply(edit) } else { super.deleteBackward(sender) }
    }

    public override func deleteForward(_ sender: Any?) {
        if !hasMarkedText(), let edit = buffer().mergeForward(selection: selectedRange()) { apply(edit) } else { super.deleteForward(sender) }
    }

    /// Cmd+↑/↓：先跳块，无块可跳时回落到文档首尾。
    public override func moveToBeginningOfDocument(_ sender: Any?) {
        if let target = buffer().prevBlockStart(from: selectedRange().location) { jump(to: target) } else { super.moveToBeginningOfDocument(sender) }
    }

    public override func moveToEndOfDocument(_ sender: Any?) {
        if let target = buffer().nextBlockStart(from: selectedRange().location) { jump(to: target) } else { super.moveToEndOfDocument(sender) }
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
        let caret = buffer().normalizedCaret(from: selectedRange().location, to: range.location)
        super.setSelectedRanges([NSValue(range: NSRange(location: caret, length: 0))], affinity: affinity, stillSelecting: stillSelecting)
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
        let storage = textStorage!
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? CueDividerAttachment === attachment { found = range.location; stop.pointee = true }
        }
        return found
    }

    func refreshDividerLabels() {
        let storage = textStorage!
        var dividers: [CueDivider] = []
        if numbering != .none { dividers = buffer().dividers() }
        for divider in dividers {
            let attachment = storage.attribute(.attachment, at: divider.location, effectiveRange: nil) as? CueDividerAttachment
            setLabel(numbering.label(forSegment: divider.sequence), on: attachment)
        }
        guard numbering == .none else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
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

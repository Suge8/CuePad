#if canImport(UIKit)
import CueText
import UIKit

extension CueTextView {
    /// 在光标处插入一条分割线（外部工具栏的按钮调用）。
    public func insertDivider() {
        apply(core.buffer().dividerEdit(selection: selectedRange))
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

    // MARK: 读屏

    /// 读屏念的文字：分割线（占一个 U+FFFC）读作"分割线"，图片等其它附件照旧。
    /// 附件没有读屏标签的接口（NSTextAttachment 没有；挂在图片上的标签 UITextView 不用），所以由文本视图的值来说。
    public override var accessibilityValue: String? {
        get {
            let spoken = NSMutableString(string: textStorage.string)
            textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length), options: .reverse) { attachment, range, _ in
                if attachment is CueDividerAttachment { spoken.replaceCharacters(in: range, with: "分割线") }
            }
            return spoken as String
        }
        set {}
    }

    // MARK: 键盘

    /// 分割线下一行的行首 Backspace 整条删掉分割线；其它情况走系统默认删除。
    public override func deleteBackward() {
        if markedTextRange == nil, let edit = core.buffer().mergeBackward(selection: selectedRange) { apply(edit) } else { super.deleteBackward() }
    }

    /// 硬件键盘前向删除：分割线上一行的行尾按下时整条删掉分割线，返回 true 表示已处理；其它位置交还系统默认。
    func handleForwardDelete() -> Bool {
        guard markedTextRange == nil, let edit = core.buffer().mergeForward(selection: selectedRange) else { return false }
        apply(edit)
        return true
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardDeleteForward }), handleForwardDelete() { return }
        super.pressesBegan(presses, with: event)
    }

    // MARK: 光标

    /// 空光标不落在分割线行上：程序、键盘与手势导致的选区变化都经这两个入口规范化；有没有选区变了就报告。
    public override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = normalized(newValue)
            reportSelection()
        }
    }

    public override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            defer { reportSelection() }
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

    func reportSelection() {
        let selecting = selectedRange.length > 0
        guard selecting != reportedSelection else { return }
        reportedSelection = selecting
        onSelectionChange?(selecting)
    }
}
#endif

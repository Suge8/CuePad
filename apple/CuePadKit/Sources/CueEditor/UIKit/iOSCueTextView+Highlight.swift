#if canImport(UIKit)
import CueText
import UIKit

extension CueTextView {
    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager as? NSTextContentStorage,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// 变量高亮用 TextKit 渲染属性：不写 NSTextStorage，不进撤销栈，不改输入法的标记文本样式。
    /// `edited` 为 nil 时重扫全文，否则只扫被编辑的段落。
    func refreshVariableHighlight(around edited: NSRange?) {
        guard let layout = textLayoutManager else { return }
        let text = textStorage.mutableString
        let whole = NSRange(location: 0, length: text.length)
        let paragraph = edited.map { text.paragraphRange(for: NSIntersectionRange($0, whole)) } ?? whole
        if let cleared = textRange(paragraph) {
            layout.removeRenderingAttribute(.foregroundColor, for: cleared)
            layout.removeRenderingAttribute(.backgroundColor, for: cleared)
        }
        for range in CueVariables.ranges(in: text as String, within: paragraph) {
            guard let target = textRange(range) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: style.variableColor, for: target)
            layout.addRenderingAttribute(.backgroundColor, value: style.variableBackground, for: target)
        }
    }
}
#endif

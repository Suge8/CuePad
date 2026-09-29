#if canImport(AppKit)
import AppKit
import CueText

extension NSAttributedString.Key {
    /// 代码行整行底色（值是 NSColor）；只存在于展示用的段落，由 `CueCodeFragment` 铺底。
    static let cueCodeBand = NSAttributedString.Key("cue.codeBand")
}

/// 轻装饰只改"展示"：TextKit 向内容管理器要每个段落时，返回一份带样式的副本，
/// NSTextStorage 里的文本与属性、撤销栈和存储格式都不受影响。
/// 渲染属性只能改颜色、下划线这类不影响布局的属性，标题字号字重只能走这条路。
final class DecorationDelegate: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate, @unchecked Sendable {
    private nonisolated(unsafe) weak var textView: CueTextView?

    @MainActor init(textView: CueTextView) { self.textView = textView }

    nonisolated func textContentStorage(_ contentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        MainActor.assumeIsolated { UncheckedBox(value: textView?.decoratedParagraph(range)) }.value
    }

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let band = paragraph.attributedString.attribute(.cueCodeBand, at: 0, effectiveRange: nil) as? NSColor {
            return CueCodeFragment(textElement: textElement, range: textElement.elementRange, band: band)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// TextKit 的回调都在主线程；NSTextParagraph 没有 Sendable 标注，用盒子带出 assumeIsolated。
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// 代码行：在文字之前把底色铺满整个行宽（文字自带的底色只覆盖字形）。
final class CueCodeFragment: NSTextLayoutFragment {
    private let band: NSColor

    init(textElement: NSTextElement, range: NSTextRange?, band: NSColor) {
        self.band = band
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    /// 以片段原点为坐标原点：从容器左缘到右缘，高度同片段。
    private var bandRect: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        return CGRect(x: -layoutFragmentFrame.minX, y: 0, width: width, height: layoutFragmentFrame.height)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(bandRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setFillColor(band.cgColor)
        context.fill(bandRect.offsetBy(dx: point.x, dy: point.y))
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

extension CueTextView {
    func decoratedParagraph(_ range: NSRange) -> NSTextParagraph? {
        let storage = textStorage!
        let text = storage.mutableString
        let hasNewline = range.length > 0 && text.character(at: NSMaxRange(range) - 1) == 0x0A
        let lineRange = NSRange(location: range.location, length: range.length - (hasNewline ? 1 : 0))
        let style = decorations.style(ofLine: text.substring(with: lineRange), at: range.location)
        guard style.isTitle || style.kind != .body || !style.inlineCode.isEmpty else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        decorate(paragraph, style: style, lineLength: lineRange.length)
        return NSTextParagraph(attributedString: paragraph)
    }

    private func decorate(_ paragraph: NSMutableAttributedString, style: CueLineStyle, lineLength: Int) {
        let whole = NSRange(location: 0, length: paragraph.length)
        let isCode = style.kind == .fence || style.kind == .code
        if isCode {
            paragraph.addAttributes([.font: theme.codeFont, .cueCodeBand: theme.codeBackground], range: whole)
        } else if style.isTitle {
            paragraph.addAttributes([.font: theme.titleFont, .paragraphStyle: paragraphStyle()], range: whole)
        } else if style.kind == .heading {
            paragraph.addAttributes([.font: theme.headingFont, .paragraphStyle: paragraphStyle(spacingBefore: theme.headingSpacing)], range: whole)
        } else if style.kind == .list {
            let prefix = paragraph.string.utf16.prefix(style.markerLength)
            let hang = (String(decoding: prefix, as: UTF16.self) as NSString).size(withAttributes: [.font: theme.font]).width
            paragraph.addAttribute(.paragraphStyle, value: paragraphStyle(hangingIndent: hang), range: whole)
        }
        if style.markerLength > 0 {
            paragraph.addAttribute(.foregroundColor, value: theme.markerColor, range: NSRange(location: 0, length: style.markerLength))
        }
        for code in style.inlineCode {
            paragraph.addAttributes([.font: theme.codeFont, .backgroundColor: theme.codeBackground], range: code)
            for tick in [NSRange(location: code.location, length: 1), NSRange(location: NSMaxRange(code) - 1, length: 1)] {
                paragraph.addAttribute(.foregroundColor, value: theme.markerColor, range: tick)
            }
        }
    }

    private func paragraphStyle(spacingBefore: CGFloat = 0, hangingIndent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacingBefore = spacingBefore
        style.headIndent = hangingIndent
        return style
    }

    // MARK: 刷新已排版的段落
    // TextKit 不会因为装饰上下文变了就重新询问未被编辑的段落，必须发一次"仅属性"的编辑通知；
    // 通知不改文本、不进撤销栈，`storageDidProcessEditing` 对它直接忽略。

    func restyle(_ range: NSRange) {
        guard range.length > 0 else { return }
        textStorage!.edited(.editedAttributes, range: range, changeInLength: 0)
    }

    /// 编辑之后，让受影响的未编辑段落按新上下文重排：标题易主、围栏奇偶翻转。
    func restyleAfter(_ edits: [(range: NSRange, delta: Int)]) {
        let old = flushedDecorations
        flushedDecorations = decorations
        let length = textStorage!.length
        guard edits.count == 1 else { return restyle(NSRange(location: 0, length: length)) }
        let (edit, delta) = edits[0]
        if old.titleLocation != decorations.titleLocation {
            let mappedOld = old.titleLocation.flatMap { location -> Int? in
                if location < edit.location { return location }
                return location >= NSMaxRange(edit) - delta ? location + delta : nil
            }
            [mappedOld, decorations.titleLocation].compactMap { $0 }.forEach { restyle(paragraphRange(at: $0)) }
        }
        if (decorations.fenceCount - old.fenceCount) % 2 != 0 {
            let start = min(NSMaxRange(edit), length)
            restyle(NSRange(location: start, length: length - start))
        }
    }

    private func paragraphRange(at location: Int) -> NSRange {
        let text = textStorage!.mutableString
        return text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
    }
}
#endif

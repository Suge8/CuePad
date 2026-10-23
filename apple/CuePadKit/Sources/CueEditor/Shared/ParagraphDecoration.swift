import CueText
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension NSAttributedString.Key {
    /// 代码行整行底色（值是 CueColor）；只存在于展示用的段落，由 `CueCodeFragment` 铺底。
    static let cueCodeBand = NSAttributedString.Key("cue.codeBand")
}

/// 轻装饰只改"展示"：TextKit 向内容管理器要每个段落时，返回一份带样式的副本，
/// NSTextStorage 里的文本与属性、撤销栈和存储格式都不受影响。
/// 渲染属性只能改颜色、下划线这类不影响布局的属性，`#` 标题的字号字重只能走这条路。
final class DecorationDelegate: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate, Sendable {
    private weak let core: EditorCore?

    @MainActor init(core: EditorCore) { self.core = core }

    nonisolated func textContentStorage(_ contentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        MainActor.assumeIsolated { UncheckedBox(value: core?.decoratedParagraph(range)) }.value
    }

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let band = paragraph.attributedString.attribute(.cueCodeBand, at: 0, effectiveRange: nil) as? CueColor {
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
    private let band: CueColor

    init(textElement: NSTextElement, range: NSTextRange?, band: CueColor) {
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

extension EditorCore {
    func decoratedParagraph(_ range: NSRange) -> NSTextParagraph? {
        let text = storage.mutableString
        let hasNewline = range.length > 0 && text.character(at: NSMaxRange(range) - 1) == 0x0A
        let lineRange = NSRange(location: range.location, length: range.length - (hasNewline ? 1 : 0))
        let line = decorations.style(ofLine: text.substring(with: lineRange), at: range.location)
        let title = range.location == 0 ? style.title : nil
        guard title != nil || line.kind != .body || !line.inlineCode.isEmpty || !line.links.isEmpty else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        if let title {
            // 标题行不认 Markdown 记号：它就是一件事的名字
            let spacing = NSMutableParagraphStyle()
            spacing.lineSpacing = style.lineSpacing
            spacing.paragraphSpacing = title.spacing
            paragraph.addAttributes(
                [.font: title.font, .foregroundColor: title.color, .paragraphStyle: spacing], range: NSRange(location: 0, length: paragraph.length))
        } else {
            decorate(paragraph, line: line)
        }
        return NSTextParagraph(attributedString: paragraph)
    }

    private func decorate(_ paragraph: NSMutableAttributedString, line: CueLineStyle) {
        let whole = NSRange(location: 0, length: paragraph.length)
        let isCode = line.kind == .fence || line.kind == .code
        if isCode {
            paragraph.addAttributes([.font: style.codeFont, .cueCodeBand: resolved(style.codeBackground)], range: whole)
        } else if line.kind == .heading {
            paragraph.addAttributes([.font: style.headingFont, .paragraphStyle: paragraphStyle(spacingBefore: style.headingSpacing)], range: whole)
        } else if line.kind == .list {
            let prefix = paragraph.string.utf16.prefix(line.markerLength)
            let hang = (String(decoding: prefix, as: UTF16.self) as NSString).size(withAttributes: [.font: style.font]).width
            paragraph.addAttribute(.paragraphStyle, value: paragraphStyle(hangingIndent: hang), range: whole)
        }
        if line.markerLength > 0 {
            paragraph.addAttribute(.foregroundColor, value: style.markerColor, range: NSRange(location: 0, length: line.markerLength))
        }
        for link in line.links {
            // 链接是正文的墨色加下划线，不另上色：签名色只给焦点
            paragraph.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: link.label)
            for syntax in link.syntax { paragraph.addAttribute(.foregroundColor, value: style.markerColor, range: syntax) }
        }
        for code in line.inlineCode {
            paragraph.addAttributes([.font: style.codeFont, .backgroundColor: style.codeBackground], range: code)
            for tick in [NSRange(location: code.location, length: 1), NSRange(location: NSMaxRange(code) - 1, length: 1)] {
                paragraph.addAttribute(.foregroundColor, value: style.markerColor, range: tick)
            }
        }
    }

    private func paragraphStyle(spacingBefore: CGFloat = 0, hangingIndent: CGFloat = 0) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.headIndent = hangingIndent
        return paragraph
    }

    // MARK: 刷新已排版的段落
    // TextKit 不会因为装饰上下文变了就重新询问未被编辑的段落，必须发一次"仅属性"的编辑通知；
    // 通知不改文本、不进撤销栈，`storageDidProcessEditing` 对它直接忽略。

    func restyle(_ range: NSRange) {
        guard range.length > 0 else { return }
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
    }

    /// 编辑之后，让受影响的未编辑段落按新上下文重排：围栏奇偶翻转。
    func restyleAfter(_ edits: [NSRange]) {
        let old = flushedDecorations
        flushedDecorations = decorations
        let length = storage.length
        guard edits.count == 1 else { return restyle(NSRange(location: 0, length: length)) }
        let edit = edits[0]
        // 首段是标题：回车拆出、退格并进来的那一段不在编辑范围里，跟着换样子
        if style.title != nil {
            let first = storage.mutableString.paragraphRange(for: NSRange(location: 0, length: 0))
            if edit.location <= NSMaxRange(first), NSMaxRange(first) < length {
                restyle(NSUnionRange(first, storage.mutableString.paragraphRange(for: NSRange(location: NSMaxRange(first), length: 0))))
            }
        }
        if (decorations.fenceCount - old.fenceCount) % 2 != 0 {
            let start = min(NSMaxRange(edit), length)
            restyle(NSRange(location: start, length: length - start))
        }
    }
}

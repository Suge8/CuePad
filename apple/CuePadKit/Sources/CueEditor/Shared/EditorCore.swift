import CueText
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 平台宿主（NSTextView / UITextView 的薄封装）向共享核心提供的少量能力。
@MainActor
protocol CueEditorHost: AnyObject {
    var numbering: CueNumbering { get }
    /// 动态色按当前外观解析成固定色（绘制到 CGContext 的底色用）。
    func resolvedColor(_ color: CueColor) -> CueColor
    /// 分片预布局每推进一片：让宿主按最新用量重算内容尺寸。
    func layoutDidAdvance()
    /// 附件的绘制内容变了（缩略图解码完成）：让宿主重排刷新。
    func needsRelayout()
    /// 屏幕像素与点的比例：附件图按像素尺寸预先画好。
    var displayScale: CGFloat { get }
    func blockActionRequested(_ action: CueBlockAction)
}

enum CueTextStack {
    /// 两个平台共用的 TextKit 2 栈；宿主用它构造 NSTextView / UITextView，永远不碰 `.layoutManager`。
    @MainActor
    static func make() -> (content: NSTextContentStorage, layout: NSTextLayoutManager, container: NSTextContainer) {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        return (content, layout, container)
    }
}

/// 编辑器的平台无关核心：存储格式与运行时富文本的互转、变量高亮、轻装饰、分块编号与动作、
/// 图片懒加载与分片预布局。平台宿主只负责视图、输入与系统交互。
@MainActor
final class EditorCore {
    private weak var host: (any CueEditorHost)?
    let imageStore: any CueImageStore
    let storage: NSTextStorage
    let content: NSTextContentStorage
    let layout: NSTextLayoutManager
    /// 宿主缩放后的实际样式，所有排版都读它。
    var style: CueEditorTheme

    /// 自上次刷新以来的编辑：新坐标下的范围与长度变化。
    private var pendingEdits: [(range: NSRange, delta: Int)] = []
    /// 现有段落是按哪份装饰上下文排版的。
    var flushedDecorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    var decorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    private var decorationDelegate: DecorationDelegate?
    private(set) lazy var settler = LayoutSettler(core: self)
    private(set) lazy var thumbnails = ThumbnailLoader(core: self)
    var displayScale: CGFloat { host?.displayScale ?? 2 }

    init(host: any CueEditorHost, imageStore: any CueImageStore, style: CueEditorTheme, storage: NSTextStorage, content: NSTextContentStorage, layout: NSTextLayoutManager) {
        self.host = host
        self.imageStore = imageStore
        self.style = style
        self.storage = storage
        self.content = content
        self.layout = layout
        let delegate = DecorationDelegate(core: self)
        decorationDelegate = delegate
        content.delegate = delegate
        layout.delegate = delegate
    }

    // MARK: 存储格式 <-> 运行时

    func stored() -> String {
        CueFormat.serialize(tokens(in: NSRange(location: 0, length: storage.length)))
    }

    func tokens(in range: NSRange) -> [CueToken] {
        var tokens: [CueToken] = []
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            switch value {
            case let image as CueImageAttachment: tokens.append(.image(image.imageID))
            case is CueDividerAttachment: tokens.append(.split)
            default: tokens.append(.text(storage.attributedSubstring(from: run).string))
            }
        }
        return tokens
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        return [.font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph]
    }

    func attributed(_ tokens: [CueToken]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for token in tokens {
            switch token {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: baseAttributes))
            case .image(let id): result.append(imageString(id: id))
            case .split: result.append(dividerString())
            }
        }
        return result
    }

    func imageString(id: String) -> NSAttributedString {
        let attachment = CueImageAttachment(id: id, fileURL: imageStore.fileURL(for: id))
        attachment.core = self
        return attachmentString(attachment)
    }

    func dividerString() -> NSAttributedString {
        let attachment = CueDividerAttachment()
        attachment.core = self
        return attachmentString(attachment)
    }

    private func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// 分块编辑（`CueEdit.insert` 里的 U+FFFC 是分隔控件）对应的富文本。
    func insertion(for edit: CueEdit) -> NSAttributedString {
        let insertion = NSMutableAttributedString()
        for (index, part) in edit.insert.components(separatedBy: String(UnicodeScalar(CueFormat.objectCharacter)!)).enumerated() {
            if index > 0 { insertion.append(dividerString()) }
            insertion.append(NSAttributedString(string: part, attributes: baseAttributes))
        }
        return insertion
    }

    func buffer() -> CueBuffer {
        let storage = storage
        return CueBuffer(text: storage.mutableString) { index in
            index < storage.length && storage.attribute(.attachment, at: index, effectiveRange: nil) is CueDividerAttachment
        }
    }

    /// 整体替换正文；撤销栈、选区、`onChange` 由宿主处理。
    func load(_ stored: String) {
        storage.setAttributedString(attributed(CueFormat.parse(stored)))
        pendingEdits = []
        flushedDecorations = decorations
        refreshVariableHighlight(around: nil)
        refreshDividerLabels()
        settler.restart()
    }

    /// 主题或字号档位变了：重刷基础属性、高亮、装饰并重新预布局。
    func styleDidChange() {
        if storage.length > 0 {
            storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        refreshVariableHighlight(around: nil)
        restyle(NSRange(location: 0, length: storage.length))
        settler.restart()
    }

    // MARK: 编辑记账

    /// storage 的 didProcessEditing：此刻 TextKit 的内容管理器还没同步新文本，位置换算要等下一个同步点。
    func storageDidProcessEditing() {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        pendingEdits.append((storage.editedRange, storage.changeInLength))
        decorations = CueDecorations(buffer())
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    /// 同步点（一次编辑结束、组合输入的每一步）之后刷新高亮与装饰；兜底的主队列回调覆盖撤销等其它路径。
    func flushHighlight() {
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        // 多次编辑累积时新旧坐标混杂，直接全文重扫
        refreshVariableHighlight(around: edits.count == 1 ? edits[0].range : nil)
        restyleAfter(edits)
        if (host?.numbering ?? .none) != .none { refreshDividerLabels() }
    }

    func resolved(_ color: CueColor) -> CueColor { host?.resolvedColor(color) ?? color }
    func layoutDidAdvance() { host?.layoutDidAdvance() }
    func needsRelayout() { host?.needsRelayout() }

    // MARK: 变量高亮

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// 变量高亮用 TextKit 渲染属性：不写 NSTextStorage，不进撤销栈，不改输入法的标记文本样式。
    /// `edited` 为 nil 时重扫全文，否则只扫被编辑的段落。
    func refreshVariableHighlight(around edited: NSRange?) {
        let text = storage.mutableString
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

    // MARK: 图片重绘

    /// 缩略图解码完成后重绘引用它的附件：TextKit 缓存了片段的渲染结果，必须让对应片段失效重排。
    func redrawImages(at url: URL) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let image = value as? CueImageAttachment, image.fileURL == url, let target = textRange(range) else { return }
            layout.invalidateLayout(for: target)
        }
        needsRelayout()
    }

    // MARK: 分块编号与动作

    func performDividerAction(_ kind: CueBlockActionKind, from attachment: CueDividerAttachment) {
        guard let location = dividerLocation(of: attachment),
              let divider = buffer().dividers().first(where: { $0.location == location }) else { return }
        performBlockAction(kind, blockIndex: divider.blockIndex)
    }

    func performBlockAction(_ kind: CueBlockActionKind, blockIndex: Int) {
        let segments = CueSegments.parse(stored())
        guard segments.indices.contains(blockIndex) else { return }
        host?.blockActionRequested(CueBlockAction(kind: kind, blockIndex: blockIndex, text: segments[blockIndex].text))
    }

    private func dividerLocation(of attachment: CueDividerAttachment) -> Int? {
        var found: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? CueDividerAttachment === attachment { found = range.location; stop.pointee = true }
        }
        return found
    }

    func refreshDividerLabels() {
        let numbering = host?.numbering ?? .none
        if numbering != .none {
            for divider in buffer().dividers() {
                let attachment = storage.attribute(.attachment, at: divider.location, effectiveRange: nil) as? CueDividerAttachment
                setLabel(numbering.label(forSegment: divider.sequence), on: attachment)
            }
            return
        }
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

/// 文本视图树里的全部分隔线视图（主题变化时要求它们重绘）。
@MainActor
func cueDividerViews(in root: CueView) -> [CueDividerView] {
    (root as? CueDividerView).map { [$0] } ?? root.subviews.flatMap(cueDividerViews(in:))
}

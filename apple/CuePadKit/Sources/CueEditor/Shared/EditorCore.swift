import CueText
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
protocol CueEditorHost: AnyObject {
    func resolvedColor(_ color: CueColor) -> CueColor
    func layoutDidAdvance()
    func needsRelayout()
    var displayScale: CGFloat { get }
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
        // 字离编辑器左右沿只隔主题给的留白（`CueEditorTheme.horizontalInset`），不再多系统默认的 5pt 行片段留白：宿主按同一个数对齐别的字
        container.lineFragmentPadding = 0
        layout.textContainer = container
        return (content, layout, container)
    }
}

@MainActor
final class EditorCore {
    private weak var host: (any CueEditorHost)?
    let files: any CueFileStore
    let storage: NSTextStorage
    let content: NSTextContentStorage
    let layout: NSTextLayoutManager
    var style: CueEditorTheme

    private var loads = 0
    private var edits = 0
    private var pendingEdits: [NSRange] = []
    var flushedDecorations = CueDecorations("")
    var decorations = CueDecorations("")
    private var decorationDelegate: DecorationDelegate?
    private(set) lazy var settler = LayoutSettler(core: self)
    private(set) lazy var thumbnails = ThumbnailLoader(core: self)
    var displayScale: CGFloat { host?.displayScale ?? 2 }
    var fileStatus: (_ key: String, _ name: String, _ file: URL?) -> CueFileStatus = { _, name, _ in
        CueFileStatus(detail: AttachmentKey.format(ofName: name).uppercased())
    }
    var fileIcon: (String) -> CueImage? = { _ in nil }

    init(host: any CueEditorHost, files: any CueFileStore, style: CueEditorTheme, storage: NSTextStorage, content: NSTextContentStorage, layout: NSTextLayoutManager) {
        self.host = host
        self.files = files
        self.style = style
        self.storage = storage
        self.content = content
        self.layout = layout
        let delegate = DecorationDelegate(core: self)
        decorationDelegate = delegate
        content.delegate = delegate
        layout.delegate = delegate
    }

    func stored() -> String {
        CueFormat.serialize(tokens(in: NSRange(location: 0, length: storage.length)))
    }

    func tokens(in range: NSRange) -> [CueToken] {
        var tokens: [CueToken] = []
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            switch value {
            case let image as CueImageAttachment: tokens.append(.image(image.key))
            case let file as CueFileAttachment: tokens.append(.file(key: file.key, name: file.name))
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
            case .image(let key): result.append(imageString(key: key))
            case .file(let key, let name): result.append(fileString(key: key, name: name))
            }
        }
        return result
    }

    func imageString(key: String) -> NSAttributedString {
        let attachment = CueImageAttachment(key: key, fileURL: files.fileURL(for: key))
        attachment.core = self
        return attachmentString(attachment)
    }

    func fileString(key: String, name: String) -> NSAttributedString {
        let attachment = CueFileAttachment(key: key, name: CueFormat.fileName(name))
        attachment.core = self
        return attachmentString(attachment)
    }

    func attachmentString(key: String, name: String) -> NSAttributedString {
        AttachmentKey.isImage(key) ? imageString(key: key) : fileString(key: key, name: name)
    }

    private func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    func importFiles(
        _ sources: [IncomingFile], at start: NSRange, selection current: @escaping @MainActor () -> NSRange,
        completion: @escaping @MainActor (Result<(NSAttributedString, NSRange)?, any Error>) -> Void
    ) {
        let files = files, started = loads, edited = edits
        Task {
            let stored = await Self.store(sources, in: files)
            completion(stored.map { pairs in
                guard started == loads else { return nil }
                let range = edited == edits ? start : NSRange(location: NSMaxRange(current()), length: 0)
                let result = NSMutableAttributedString()
                for (index, pair) in pairs.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                    result.append(attachmentString(key: pair.key, name: pair.name))
                }
                return (result, range)
            })
        }
    }

    @concurrent private static func store(_ sources: [IncomingFile], in files: any CueFileStore) async -> Result<[(key: String, name: String)], any Error> {
        do {
            var stored: [(key: String, name: String)] = []
            for source in sources { stored.append(try await source.store(in: files)) }
            return .success(stored)
        } catch {
            return .failure(error)
        }
    }

    func onOwnLine(_ insertion: NSAttributedString, replacing range: NSRange) -> NSAttributedString {
        let text = storage.mutableString, newline: unichar = 0x0A
        let result = NSMutableAttributedString(attributedString: insertion)
        if range.location > 0, text.character(at: range.location - 1) != newline {
            result.insert(NSAttributedString(string: "\n", attributes: baseAttributes), at: 0)
        }
        if NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) != newline {
            result.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        return result
    }

    func fileChip(key: String, name: String, size: CGSize) -> CueImage {
        let url = files.fileURL(for: key)
        let status = fileStatus(key, name, url)
        let thumbnail = url.flatMap { thumbnails.chip(key: key, at: $0) }
        var style = style
        style.imagePlaceholderColor = resolved(style.imagePlaceholderColor)
        style.textColor = resolved(style.textColor)
        style.markerColor = resolved(style.markerColor)
        let symbol = thumbnail == nil ? fileIcon(name).map { CueImageRendering.tinted($0, color: style.markerColor, size: style.fileGlyphSize) } : nil
        return CueImageRendering.canvas(size: size) { context in
            FileChip.draw(in: context, size: size, name: name, status: status, thumbnail: thumbnail, symbol: symbol, style: style)
        }
    }

    func missingImageLabel(_ key: String) -> String { fileStatus(key, "", nil).detail }

    func openableAttachment(at index: Int) -> (key: String, name: String)? {
        guard index >= 0, index < storage.length else { return nil }
        let hit: (key: String, name: String, file: URL?)
        switch storage.attribute(.attachment, at: index, effectiveRange: nil) {
        case let file as CueFileAttachment: hit = (file.key, file.name, files.fileURL(for: file.key))
        case let image as CueImageAttachment: hit = (image.key, "", image.fileURL)
        default: return nil
        }
        return hit.file == nil || !hit.name.isEmpty ? (hit.key, hit.name) : nil
    }

    func load(_ stored: String) {
        loads += 1
        storage.setAttributedString(attributed(CueFormat.parse(stored)))
        pendingEdits = []
        flushedDecorations = decorations
        refreshVariableHighlight(around: nil)
        settler.restart()
    }

    func styleDidChange() {
        if storage.length > 0 {
            storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        refreshVariableHighlight(around: nil)
        restyle(NSRange(location: 0, length: storage.length))
        settler.restart()
    }

    /// storage 的 didProcessEditing：此刻 TextKit 的内容管理器还没同步新文本，位置换算要等下一个同步点。
    func storageDidProcessEditing() {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        edits += 1
        pendingEdits.append(storage.editedRange)
        decorations = CueDecorations(storage.mutableString)
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    func flushHighlight() {
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        refreshVariableHighlight(around: edits.count == 1 ? edits[0] : nil)
        restyleAfter(edits)
    }

    func resolved(_ color: CueColor) -> CueColor { host?.resolvedColor(color) ?? color }
    func layoutDidAdvance() { host?.layoutDidAdvance() }
    func needsRelayout() { host?.needsRelayout() }

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

    /// 缩略图出好后重画引用它的附件（`key` 为 nil 时全部，例如换到缩放比例不同的屏）：TextKit 缓存了片段的渲染结果，必须让对应片段失效重排。
    func redraw(key: String?) {
        redraw { attachment in
            let found = (attachment as? CueImageAttachment)?.key ?? (attachment as? CueFileAttachment)?.key
            return found != nil && (key == nil || found == key)
        }
    }

    func refreshAttachments() {
        redraw { attachment in
            switch attachment {
            case let image as CueImageAttachment: image.relocate(files.fileURL(for: image.key))
            case is CueFileAttachment: true
            default: false
            }
        }
    }

    private func redraw(where matches: (NSTextAttachment) -> Bool) {
        var any = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, matches(attachment), let target = textRange(range) else { return }
            layout.invalidateLayout(for: target)
            any = true
        }
        if any { needsRelayout() }
    }

    func stored(in range: NSRange) -> String? {
        range.length > 0 ? CueFormat.serialize(tokens(in: range)) : nil
    }
}

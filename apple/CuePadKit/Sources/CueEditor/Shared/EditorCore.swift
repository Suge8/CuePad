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
    /// 动态色按当前外观解析成固定色（绘制到 CGContext 的底色用）。
    func resolvedColor(_ color: CueColor) -> CueColor
    /// 分片预布局每推进一片：让宿主按最新用量重算内容尺寸。
    func layoutDidAdvance()
    /// 附件的绘制内容变了（缩略图解码完成）：让宿主重排刷新。
    func needsRelayout()
    /// 屏幕像素与点的比例：附件图按像素尺寸预先画好。
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

/// 编辑器的平台无关核心：存储格式（Markdown 原文）与运行时富文本的互转（只有附件——图片与文件牌——换成 U+FFFC）、变量高亮、轻装饰、
/// 附件懒加载与分片预布局。平台宿主只负责视图、输入与系统交互。
@MainActor
final class EditorCore {
    private weak var host: (any CueEditorHost)?
    let files: any CueFileStore
    let storage: NSTextStorage
    let content: NSTextContentStorage
    let layout: NSTextLayoutManager
    /// 宿主缩放后的实际样式，所有排版都读它。
    var style: CueEditorTheme

    /// 自上次刷新以来的编辑：新坐标下的范围与长度变化。
    private var pendingEdits: [NSRange] = []
    /// 现有段落是按哪份装饰上下文排版的。
    var flushedDecorations = CueDecorations("")
    var decorations = CueDecorations("")
    private var decorationDelegate: DecorationDelegate?
    private(set) lazy var settler = LayoutSettler(core: self)
    private(set) lazy var thumbnails = ThumbnailLoader(core: self)
    var displayScale: CGFloat { host?.displayScale ?? 2 }
    /// 附件此刻的样子（宿主给：类型与大小、还没到时怎么取、传了几成）；参数是键、文件名与本机那份（不在本机为 nil）。
    var fileStatus: (_ key: String, _ name: String, _ file: URL?) -> CueFileStatus = { _, name, _ in
        CueFileStatus(detail: AttachmentKey.format(ofName: name).uppercased())
    }
    /// 文件牌上没有缩略图时的记号，按文件名的类型（宿主给：图标只在 App 的图标表里）。
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

    // MARK: 存储格式 <-> 运行时

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

    /// 存好的一个附件放进正文的样子：能内联显示的图片嵌入，其余是文件牌（同 `CueFormat.markup`）。
    func attachmentString(key: String, name: String) -> NSAttributedString {
        AttachmentKey.isImage(key) ? imageString(key: key) : fileString(key: key, name: name)
    }

    private func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// 存入几个文件（拖入、粘贴、选的；任意类型，调用方持有访问权直到回调），在后台算哈希、拷贝，回调在主线程：
    /// 每个附件自成一行（文件牌、图片之间与前后的字各隔一个换行）。有一个存不进就整批不插，报那个错。
    func importFiles(_ sources: [IncomingFile], completion: @escaping @MainActor (Result<NSAttributedString, any Error>) -> Void) {
        let files = files
        Task {
            let stored = await Self.store(sources, in: files)
            completion(stored.map { pairs in
                let result = NSMutableAttributedString()
                for (index, pair) in pairs.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                    result.append(attachmentString(key: pair.key, name: pair.name))
                }
                return result
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

    /// 插进来的附件自成一行：插入处前面、后面不是换行（也不是开头、结尾）就补一个。
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

    /// 文件牌此刻的画面（`CueFileAttachment` 绘制时取）。
    func fileChip(key: String, name: String, size: CGSize) -> CueImage {
        let url = files.fileURL(for: key)
        let status = fileStatus(key, name, url)
        let thumbnail = url.flatMap { thumbnails.chip(key: key, at: $0) }
        var style = style
        style.imagePlaceholderColor = resolved(style.imagePlaceholderColor)
        style.textColor = resolved(style.textColor)
        style.markerColor = resolved(style.markerColor)
        let symbol = thumbnail == nil ? fileIcon(name).map { CueImageRendering.tinted($0, color: style.markerColor) } : nil
        return CueImageRendering.canvas(size: size) { context in
            FileChip.draw(in: context, size: size, name: name, status: status, thumbnail: thumbnail, symbol: symbol, style: style)
        }
    }

    /// 还没到这台的图片的占位上写什么（宿主给的那一行）。
    func missingImageLabel(_ key: String) -> String { fileStatus(key, "", nil).detail }

    /// 这个字符位置上的附件，连同它的键与本机有没有（点按据此打开或去取）；不是附件为 nil。
    func attachment(at index: Int) -> (key: String, name: String, file: URL?)? {
        guard index >= 0, index < storage.length else { return nil }
        switch storage.attribute(.attachment, at: index, effectiveRange: nil) {
        case let file as CueFileAttachment: return (file.key, file.name, files.fileURL(for: file.key))
        case let image as CueImageAttachment: return (image.key, "", image.fileURL)
        default: return nil
        }
    }

    /// 整体替换正文；撤销栈、选区、`onChange` 由宿主处理。
    func load(_ stored: String) {
        storage.setAttributedString(attributed(CueFormat.parse(stored)))
        pendingEdits = []
        flushedDecorations = decorations
        refreshVariableHighlight(around: nil)
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
        pendingEdits.append(storage.editedRange)
        decorations = CueDecorations(storage.mutableString)
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    /// 同步点（一次编辑结束、组合输入的每一步）之后刷新高亮与装饰；兜底的主队列回调覆盖撤销等其它路径。
    func flushHighlight() {
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        // 多次编辑累积时新旧坐标混杂，直接全文重扫
        refreshVariableHighlight(around: edits.count == 1 ? edits[0] : nil)
        restyleAfter(edits)
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

    // MARK: 附件重绘

    /// 缩略图出好后重画引用它的附件（`key` 为 nil 时全部，例如换到缩放比例不同的屏）：TextKit 缓存了片段的渲染结果，必须让对应片段失效重排。
    func redraw(key: String?) {
        redraw { attachment in
            let found = (attachment as? CueImageAttachment)?.key ?? (attachment as? CueFileAttachment)?.key
            return found != nil && (key == nil || found == key)
        }
    }

    /// 附件的文件到了、传的进度变了（宿主报来）：还没到的图片再找一次本机那份，文件牌全部重画（说明与进度现读）。
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

    /// 选中部分的存储格式；没选中为 nil。
    func stored(in range: NSRange) -> String? {
        range.length > 0 ? CueFormat.serialize(tokens(in: range)) : nil
    }
}

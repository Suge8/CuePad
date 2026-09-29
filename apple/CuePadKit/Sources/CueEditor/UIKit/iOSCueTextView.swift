#if canImport(UIKit)
import CueText
import UIKit
import UniformTypeIdentifiers

/// TextKit 2 编辑器（iOS/iPadOS）。正文的唯一事实源是 `storedText`（存储格式字符串）：
/// 图片与分隔线在运行时是 U+FFFC + 附件，所有出口（保存、复制、通知）都经序列化。
/// 全程不得访问 `UITextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: UITextView {
    public let imageStore: any CueImageStore
    /// 设计基准样式；字号会按系统字号档位（Dynamic Type）缩放后使用。
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    public var numbering: CueNumbering = .none { didSet { refreshDividerLabels() } }
    /// 用户编辑后的新正文；程序设置 `storedText` 与输入法组合期间不触发。
    public var onChange: ((String) -> Void)?
    public var onBlockAction: ((CueBlockAction) -> Void)?
    /// 图片入库失败（磁盘满、文件不可读）。失败的图片不会插入。
    public var onError: ((any Error) -> Void)?
    /// 键盘工具栏"插入图片"：外部弹出选择器，拿到图片后调用 `insertImage`。
    public var onInsertImageRequest: (() -> Void)?
    /// 键盘工具栏"变量取值"：外部弹出取值面板。
    public var onVariablesRequest: (() -> Void)?

    /// 复制与剪切写入的剪贴板。
    var pasteboard: UIPasteboard = .general
    /// 主题缩放后的实际样式，所有排版都读它。
    private(set) var style: CueEditorTheme
    /// 自上次刷新以来的编辑：新坐标下的范围与长度变化。
    private var pendingEdits: [(range: NSRange, delta: Int)] = []
    /// 现有段落是按哪份装饰上下文排版的。
    var flushedDecorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    var decorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    private var isLoading = false
    private var observers: [any NSObjectProtocol] = []
    private var decorationDelegate: DecorationDelegate?
    private var pasteDropDelegate: PasteDropDelegate?
    private lazy var settler = LayoutSettler(textView: self)
    lazy var thumbnails = ThumbnailLoader(textView: self)

    public init(imageStore: any CueImageStore, theme: CueEditorTheme = .neutral) {
        self.imageStore = imageStore
        self.theme = theme
        style = theme
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        super.init(frame: .zero, textContainer: container)
        let decoration = DecorationDelegate(textView: self)
        decorationDelegate = decoration
        content.delegate = decoration
        layout.delegate = decoration
        let paste = PasteDropDelegate(textView: self)
        pasteDropDelegate = paste
        pasteDelegate = paste
        textDropDelegate = paste
        configure()
        applyTheme()
        observe()
    }

    public required init?(coder: NSCoder) { nil }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configure() {
        allowsEditingTextAttributes = false
        smartDashesType = .no  // `---split---`、`--flag` 不能被替换成破折号
        smartQuotesType = .no
        smartInsertDeleteType = .no
        autocorrectionType = .no
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.image, .plainText, .text].map(\.identifier))
        inputAccessoryView = CueInputToolbar(textView: self)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
    }

    private func observe() {
        let center = NotificationCenter.default
        // 输入法组合期间也要记账；此刻 TextKit 的内容管理器还没同步新文本，位置换算等下一个同步点
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageDidProcessEditing() }
        })
        // 一次编辑结束的同步点（键入、组合的每一步、程序编辑都会触发）
        observers.append(center.addObserver(forName: UITextView.textDidChangeNotification, object: self, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.editDidFinish() }
        })
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: CueTextView, _) in
            view.applyTheme()
        }
    }

    // MARK: 正文

    /// 存储格式正文。读取时序列化当前内容；设置时整体替换、清空撤销栈，不触发 `onChange`。
    public var storedText: String {
        get { CueFormat.serialize(tokens(in: NSRange(location: 0, length: textStorage.length))) }
        set { load(newValue) }
    }

    private func load(_ stored: String) {
        isLoading = true
        defer { isLoading = false }
        textStorage.setAttributedString(attributed(CueFormat.parse(stored)))
        undoManager?.removeAllActions()
        selectedRange = NSRange(location: 0, length: 0)
        pendingEdits = []
        flushedDecorations = decorations
        refreshVariableHighlight(around: nil)
        refreshDividerLabels()
        settler.restart()
    }

    func tokens(in range: NSRange) -> [CueToken] {
        var tokens: [CueToken] = []
        textStorage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            switch value {
            case let image as CueImageAttachment: tokens.append(.image(image.imageID))
            case is CueDividerAttachment: tokens.append(.split)
            default: tokens.append(.text(textStorage.attributedSubstring(from: run).string))
            }
        }
        return tokens
    }

    // MARK: 运行时富文本

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
        attachment.owner = self
        return attachmentString(attachment)
    }

    func dividerString() -> NSAttributedString {
        let attachment = CueDividerAttachment()
        attachment.owner = self
        return attachmentString(attachment)
    }

    private func attachmentString(_ attachment: NSTextAttachment) -> NSAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    // MARK: 主题与动态字体

    /// 设计基准字号按系统字号档位缩放；默认档位下原样使用。
    private func scaledStyle() -> CueEditorTheme {
        func scaled(_ font: UIFont, _ textStyle: UIFont.TextStyle) -> UIFont {
            let size = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: font.pointSize, compatibleWith: traitCollection)
            return size == font.pointSize ? font : font.withSize(size)
        }
        var result = theme
        result.font = scaled(theme.font, .body)
        result.codeFont = scaled(theme.codeFont, .body)
        result.titleFont = scaled(theme.titleFont, .title1)
        result.headingFont = scaled(theme.headingFont, .title2)
        return result
    }

    private func applyTheme() {
        style = scaledStyle()
        backgroundColor = style.backgroundColor
        textContainerInset = UIEdgeInsets(top: style.verticalInset, left: style.horizontalInset, bottom: style.verticalInset, right: style.horizontalInset)
        typingAttributes = baseAttributes
        if textStorage.length > 0 {
            textStorage.addAttributes(baseAttributes, range: NSRange(location: 0, length: textStorage.length))
        }
        refreshVariableHighlight(around: nil)
        restyle(NSRange(location: 0, length: textStorage.length))
        dividerViews().forEach { $0.setNeedsDisplay() }
        settler.restart()
    }

    func dividerViews() -> [CueDividerView] {
        func walk(_ view: UIView) -> [CueDividerView] {
            (view as? CueDividerView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(self)
    }

    // MARK: 编辑通知

    private func storageDidProcessEditing() {
        guard textStorage.editedMask.contains(.editedCharacters) else { return }
        pendingEdits.append((textStorage.editedRange, textStorage.changeInLength))
        decorations = CueDecorations(buffer())
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    /// 同步点之后刷新高亮与装饰；兜底的主队列回调覆盖撤销等其它路径。
    func flushHighlight() {
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        // 多次编辑累积时新旧坐标混杂，直接全文重扫
        refreshVariableHighlight(around: edits.count == 1 ? edits[0].range : nil)
        restyleAfter(edits)
        if numbering != .none { refreshDividerLabels() }
    }

    private func editDidFinish() {
        flushHighlight()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, markedTextRange == nil { onChange?(storedText) }
    }

    public override var bounds: CGRect {
        didSet { if bounds.width != oldValue.width { settler.restart() } }
    }
}
#endif

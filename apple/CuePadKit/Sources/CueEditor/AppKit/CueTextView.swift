#if canImport(AppKit)
import AppKit
import CueText

/// TextKit 2 编辑器视图。正文的唯一事实源是 `storedText`（存储格式字符串）：
/// 图片与分隔线在运行时是 U+FFFC + 附件，所有出口（保存、复制、通知）都经序列化，永不归档 RTFD。
/// 全程不得访问 `NSTextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: NSTextView {
    public let imageStore: any CueImageStore
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    public var numbering: CueNumbering = .none { didSet { refreshDividerLabels() } }
    /// 用户编辑后的新正文；程序设置 `storedText` 不触发。
    public var onChange: ((String) -> Void)?
    public var onBlockAction: ((CueBlockAction) -> Void)?
    /// 图片入库失败（磁盘满、文件不可读）。失败的图片不会插入。
    public var onError: ((any Error) -> Void)?

    private var isLoading = false
    /// 自上次刷新以来的编辑：新坐标下的范围与长度变化。
    private var pendingEdits: [(range: NSRange, delta: Int)] = []
    /// 现有段落是按哪份装饰上下文排版的。
    var flushedDecorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    var decorations = CueDecorations(CueBuffer(text: "", isSplit: { _ in false }))
    private var decorationDelegate: DecorationDelegate?
    private var editObserver: (any NSObjectProtocol)?
    private lazy var settler = LayoutSettler(textView: self)
    lazy var thumbnails = ThumbnailLoader(textView: self)

    public init(imageStore: any CueImageStore, theme: CueEditorTheme = .neutral) {
        self.imageStore = imageStore
        self.theme = theme
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        super.init(frame: .zero, textContainer: container)
        let delegate = DecorationDelegate(textView: self)
        decorationDelegate = delegate
        content.delegate = delegate
        layout.delegate = delegate
        configure()
        applyTheme()
        // 输入法组合期间 didChangeNotification 不触发，所以高亮挂在 storage 的 didProcessEditing 上。
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.storageDidProcessEditing() } }
    }

    public required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
    }

    private func configure() {
        isRichText = true  // 附件需要富文本；格式一律由主题决定，序列化时忽略
        importsGraphics = true  // 让拖入的图片文件被接受
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false  // `---split---`、`--flag` 不能被替换成破折号
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: 10_000_000, height: 10_000_000)
    }

    // MARK: 正文

    /// 存储格式正文。读取时序列化当前内容；设置时整体替换、清空撤销栈，不触发 `onChange`。
    public var storedText: String {
        get { CueFormat.serialize(tokens(in: NSRange(location: 0, length: textStorage!.length))) }
        set { load(newValue) }
    }

    private func load(_ stored: String) {
        isLoading = true
        defer { isLoading = false }
        textStorage!.setAttributedString(attributed(CueFormat.parse(stored)))
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: 0, length: 0))
        pendingEdits = []
        flushedDecorations = decorations
        refreshVariableHighlight(around: nil)
        refreshDividerLabels()
        settler.restart()
    }

    func tokens(in range: NSRange) -> [CueToken] {
        var tokens: [CueToken] = []
        let storage = textStorage!
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            switch value {
            case let image as CueImageAttachment: tokens.append(.image(image.imageID))
            case is CueDividerAttachment: tokens.append(.split)
            default: tokens.append(.text(storage.attributedSubstring(from: run).string))
            }
        }
        return tokens
    }

    // MARK: 运行时富文本

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = theme.lineSpacing
        return [.font: theme.font, .foregroundColor: theme.textColor, .paragraphStyle: paragraph]
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

    // MARK: 主题

    private func applyTheme() {
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        textContainerInset = NSSize(width: theme.horizontalInset, height: theme.verticalInset)
        typingAttributes = baseAttributes
        if let storage = textStorage, storage.length > 0 {
            storage.addAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        refreshVariableHighlight(around: nil)
        restyle(NSRange(location: 0, length: textStorage!.length))
        dividerViews().forEach { $0.needsDisplay = true }
        settler.restart()
    }

    func dividerViews() -> [CueDividerView] {
        func walk(_ view: NSView) -> [CueDividerView] {
            (view as? CueDividerView).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(self)
    }

    // MARK: 编辑通知

    /// 输入法组合期间 `didChangeNotification` 不触发，所以从 storage 的 didProcessEditing 记账；
    /// 此刻 TextKit 的内容管理器还没同步新文本，位置换算要等到下一个同步点（见 `flushHighlight`）。
    private func storageDidProcessEditing() {
        guard textStorage!.editedMask.contains(.editedCharacters) else { return }
        pendingEdits.append((textStorage!.editedRange, textStorage!.changeInLength))
        decorations = CueDecorations(buffer())
        DispatchQueue.main.async { [weak self] in self?.flushHighlight() }
    }

    /// 同步点：一次编辑结束（`didChangeText`，组合输入的每一步也会触发）之后立刻刷新，
    /// 兜底的主队列回调覆盖撤销等其它路径。
    func flushHighlight() {
        guard !pendingEdits.isEmpty else { return }
        let edits = pendingEdits
        pendingEdits = []
        // 多次编辑累积时新旧坐标混杂，直接全文重扫
        refreshVariableHighlight(around: edits.count == 1 ? edits[0].range : nil)
        restyleAfter(edits)
        if numbering != .none { refreshDividerLabels() }
    }

    public override func didChangeText() {
        super.didChangeText()
        flushHighlight()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, !hasMarkedText() { onChange?(storedText) }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { settler.restart() }
    }
}
#endif

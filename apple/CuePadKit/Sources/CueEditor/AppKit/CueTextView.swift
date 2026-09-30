#if canImport(AppKit)
import AppKit
import CueText

/// TextKit 2 编辑器视图（macOS 薄宿主）。正文的唯一事实源是 `storedText`（存储格式字符串）：
/// 图片与分隔线在运行时是 U+FFFC + 附件，所有出口（保存、复制、通知）都经序列化，永不归档 RTFD。
/// 全程不得访问 `NSTextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: NSTextView, CueEditorHost {
    public let imageStore: any CueImageStore
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    public var numbering: CueNumbering = .none { didSet { core.refreshDividerLabels() } }
    /// 用户编辑后的新正文；程序设置 `storedText` 不触发。
    public var onChange: ((String) -> Void)?
    public var onBlockAction: ((CueBlockAction) -> Void)?
    /// 图片入库失败（磁盘满、文件不可读）。失败的图片不会插入。
    public var onError: ((any Error) -> Void)?

    private(set) var core: EditorCore!
    private var isLoading = false
    private var editObserver: (any NSObjectProtocol)?

    public init(imageStore: any CueImageStore, theme: CueEditorTheme = .neutral) {
        self.imageStore = imageStore
        self.theme = theme
        let stack = CueTextStack.make()
        super.init(frame: .zero, textContainer: stack.container)
        core = EditorCore(host: self, imageStore: imageStore, style: theme, storage: textStorage!, content: stack.content, layout: stack.layout)
        configure()
        applyTheme()
        // 输入法组合期间 didChangeNotification 不触发，所以高亮挂在 storage 的 didProcessEditing 上。
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.core.storageDidProcessEditing() } }
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
        get { core.stored() }
        set {
            isLoading = true
            defer { isLoading = false }
            core.load(newValue)
            undoManager?.removeAllActions()
            setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    // MARK: 主题

    private func applyTheme() {
        core.style = theme
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        textContainerInset = NSSize(width: theme.horizontalInset, height: theme.verticalInset)
        typingAttributes = core.baseAttributes
        core.styleDidChange()
        cueDividerViews(in: self).forEach { $0.needsDisplay = true }
    }

    // MARK: 编辑通知

    public override func didChangeText() {
        super.didChangeText()
        core.flushHighlight()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, !hasMarkedText() { onChange?(storedText) }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { core.settler.restart() }
    }

    // MARK: CueEditorHost

    func resolvedColor(_ color: CueColor) -> CueColor { color }  // 底色在绘制时按当时的外观解析
    func layoutDidAdvance() { needsLayout = true }
    func needsRelayout() { needsLayout = true }
    func blockActionRequested(_ action: CueBlockAction) { onBlockAction?(action) }
}
#endif

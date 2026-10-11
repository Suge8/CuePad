#if canImport(AppKit)
import AppKit
import CueText

/// TextKit 2 编辑器视图（macOS 薄宿主）。正文的唯一事实源是 `storedText`（存储格式字符串）：
/// 图片与分割线在运行时是 U+FFFC + 附件，所有出口（保存、复制、通知）都经序列化，永不归档 RTFD。
/// 全程不得访问 `NSTextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: NSTextView, CueEditorHost {
    public let imageStore: any CueImageStore
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    /// 用户编辑后的新正文；程序设置 `storedText` 不触发。
    public var onChange: ((String) -> Void)?
    /// 有没有选中文字变了（编辑器外的"发送选中""转为任务"据此出现）。
    public var onSelectionChange: ((Bool) -> Void)?
    /// 选中部分的存储格式；没选中为 nil。
    public var selectedStoredText: String? { core.stored(in: selectedRange()) }
    /// 选中文字时右键菜单里排在系统项前面的动作。
    public var selectionActions: [CueSelectionAction] = []
    /// 图片入库失败（磁盘满、文件不可读）。失败的图片不会插入。
    public var onError: ((any Error) -> Void)?

    /// 宿主挂着编辑器但不让用时设为 false：不接键盘、不进按键循环（不改 `isEditable`/`isSelectable`：改它们要把整段文字重新处理一遍）。
    public var acceptsInput = true

    public override var acceptsFirstResponder: Bool { acceptsInput && super.acceptsFirstResponder }

    private(set) var core: EditorCore!
    private var isLoading = false
    /// 上次报告的"有没有选区"，只在变化时再报。
    var reportedSelection = false
    private var editObserver: (any NSObjectProtocol)?

    public init(imageStore: any CueImageStore, theme: CueEditorTheme) {
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
    }

    // MARK: 编辑通知

    public override func didChangeText() {
        super.didChangeText()
        core.flushHighlight()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, !hasMarkedText() { onChange?(storedText) }
    }

    /// 换到缩放比例不同的屏：附件图按新比例重画（见 `ThumbnailLoader`）。
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        core?.redrawImages()
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
    var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

extension CueTextView {
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, let stored = selectedStoredText, !selectionActions.isEmpty else { return menu }
        for (index, action) in selectionActions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(performSelectionAction(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            item.target = self
            item.tag = index
            item.representedObject = stored
            menu.insertItem(item, at: index)
        }
        menu.insertItem(.separator(), at: selectionActions.count)
        return menu
    }

    @objc private func performSelectionAction(_ item: NSMenuItem) {
        guard selectionActions.indices.contains(item.tag), let stored = item.representedObject as? String else { return }
        selectionActions[item.tag].perform(stored)
    }
}
#endif

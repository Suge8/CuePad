#if canImport(AppKit)
import AppKit
import CueText

/// TextKit 2 编辑器视图（macOS 薄宿主）。正文的唯一事实源是 `storedText`（Markdown 原文）：
/// 只有附件（图片与文件牌）在运行时是 U+FFFC，所有出口（保存、复制、通知）都经序列化，永不归档 RTFD。
/// 全程不得访问 `NSTextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: NSTextView, CueEditorHost {
    public let files: any CueFileStore
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    public var onChange: ((String) -> Void)?
    public var onSelectionChange: ((Bool) -> Void)?
    public var selectedStoredText: String? { core.stored(in: selectedRange()) }
    public var selectionActions: [CueSelectionAction] = []
    public var onError: ((any Error) -> Void)?
    public var onOpenAttachment: ((_ key: String, _ name: String, _ picture: CGRect) -> Void)?
    public var fileStatus: (_ key: String, _ name: String, _ file: URL?) -> CueFileStatus {
        get { core.fileStatus }
        set { core.fileStatus = newValue }
    }
    public var fileIcon: (String) -> CueImage? {
        get { core.fileIcon }
        set { core.fileIcon = newValue }
    }
    /// ⌘↩ 的主动作（任务正文的"开始"）：编辑器自己接，不靠外面按钮的快捷键——浮层开着时窗口不接 ⌘ 组合键，
    /// 只交给主菜单与焦点所在的视图（`PanelHost`）。nil 时 ⌘↩ 照常往下传。
    public var onSubmit: (() -> Void)?

    private(set) var core: EditorCore!
    private var isLoading = false
    var reportedSelection = false
    private var editObserver: (any NSObjectProtocol)?

    public init(files: any CueFileStore, theme: CueEditorTheme) {
        self.files = files
        self.theme = theme
        let stack = CueTextStack.make()
        super.init(frame: .zero, textContainer: stack.container)
        core = EditorCore(host: self, files: files, style: theme, storage: textStorage!, content: stack.content, layout: stack.layout)
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
        isRichText = true
        importsGraphics = true
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: 10_000_000, height: 10_000_000)
    }

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

    public func refreshAttachments() { core.refreshAttachments() }

    private func applyTheme() {
        core.style = theme
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        textContainerInset = NSSize(width: horizontalInset(forWidth: frame.width), height: theme.verticalInset)
        typingAttributes = core.baseAttributes
        core.styleDidChange()
    }

    public override func didChangeText() {
        super.didChangeText()
        core.flushHighlight()
        invalidateIntrinsicContentSize()
        if !isLoading, !hasMarkedText() { onChange?(storedText) }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        core?.redraw(key: nil)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        let inset = horizontalInset(forWidth: newSize.width)
        if inset != textContainerInset.width { textContainerInset.width = inset }
        core.settler.restart()
    }

    private func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        guard let maxTextWidth = theme.maxTextWidth else { return theme.horizontalInset }
        return max(theme.horizontalInset, ((width - maxTextWidth) / 2).rounded(.down))
    }

    public var fittingHeight: CGFloat {
        let layout = core.layout
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.height + textContainerInset.height * 2)
    }

    func resolvedColor(_ color: CueColor) -> CueColor { color }
    func layoutDidAdvance() { needsLayout = true }
    /// 重排之外还要把画字的子视图标脏：TextKit 2 的 NSTextView 重排后不重画布局片段，附件的新样子要等别的事（打字、滚动）触发才出来。
    func needsRelayout() {
        needsLayout = true
        func redisplay(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redisplay)
        }
        redisplay(self)
    }
    var displayScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
}

extension CueTextView {
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let onSubmit, modifiers == .command, event.charactersIgnoringModifiers == "\r" {
            onSubmit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        var head: [NSMenuItem] = []
        if let stored = selectedStoredText, !selectionActions.isEmpty {
            for (index, action) in selectionActions.enumerated() {
                let item = NSMenuItem(title: action.title, action: #selector(performSelectionAction(_:)), keyEquivalent: "")
                item.image = action.image
                item.target = self
                item.tag = index
                item.representedObject = stored
                head.append(item)
            }
        }
        let insert = NSMenuItem(title: String(localized: "插入文件…"), action: #selector(chooseFiles(_:)), keyEquivalent: "")
        insert.target = self
        head += [insert, .separator()]
        for (index, item) in head.enumerated() { menu.insertItem(item, at: index) }
        return menu
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        relayoutTrailingLine()
        let selecting = selectedRange().length > 0
        guard selecting != reportedSelection else { return }
        reportedSelection = selecting
        onSelectionChange?(selecting)
    }

    /// 光标落到末尾的空行（全文以换行结尾）时，TextKit 2 只重排那一行，把它当段首、不留行距，比光标不在时矮一个行距；
    /// 贴着字摆高的宿主（任务气泡）点进空正文就跟着矮。把最后一段整段重排，它就和平时一样高。
    private func relayoutTrailingLine() {
        let text = string as NSString
        guard text.length > 0, text.character(at: text.length - 1) == 0x0A, selectedRange() == NSRange(location: text.length, length: 0) else { return }
        let layout = core.layout
        let paragraph = text.paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        guard let start = layout.location(layout.documentRange.location, offsetBy: paragraph.location),
            let range = NSTextRange(location: start, end: layout.documentRange.endLocation)
        else { return }
        layout.invalidateLayout(for: range)
    }

    @objc private func performSelectionAction(_ item: NSMenuItem) {
        guard selectionActions.indices.contains(item.tag), let stored = item.representedObject as? String else { return }
        selectionActions[item.tag].perform(stored)
    }
}
#endif

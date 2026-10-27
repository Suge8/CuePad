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
    /// 用户编辑后的新正文；程序设置 `storedText` 不触发。
    public var onChange: ((String) -> Void)?
    /// 有没有选中文字变了（编辑器外的"发送选中""转为任务"据此出现）。
    public var onSelectionChange: ((Bool) -> Void)?
    /// 选中部分的存储格式；没选中为 nil。
    public var selectedStoredText: String? { core.stored(in: selectedRange()) }
    /// 选中文字时右键菜单里排在系统项前面的动作。
    public var selectionActions: [CueSelectionAction] = []
    /// 附件入库失败（磁盘满、文件不可读、太大）。失败的附件不会插入。
    public var onError: ((any Error) -> Void)?
    /// 点了还没到这台的附件（文件牌或图片）：宿主去 iCloud 取，到了调 `refreshAttachments`。
    public var onFetchFile: ((String) -> Void)?
    /// 附件此刻的样子（见 `CueFileStatus`）：参数是键、文件名与本机那份（不在本机为 nil）。
    public var fileStatus: (_ key: String, _ name: String, _ file: URL?) -> CueFileStatus {
        get { core.fileStatus }
        set { core.fileStatus = newValue }
    }
    /// 文件牌上没有缩略图时的记号，按文件名（宿主给）。
    public var fileIcon: (String) -> CueImage? {
        get { core.fileIcon }
        set { core.fileIcon = newValue }
    }
    /// ⌘↩ 的主动作（任务正文的"开始"）：编辑器自己接，不靠外面按钮的快捷键——浮层开着时窗口不接 ⌘ 组合键，
    /// 只交给主菜单与焦点所在的视图（`PanelHost`）。nil 时 ⌘↩ 照常往下传。
    public var onSubmit: (() -> Void)?

    private(set) var core: EditorCore!
    private var isLoading = false
    /// 上次报告的"有没有选区"，只在变化时再报。
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
        isRichText = true  // 附件需要富文本；格式一律由主题决定，序列化时忽略
        importsGraphics = true  // 让拖入的文件被接受
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false  // 分割线 `---`、`--flag` 不能被替换成破折号
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

    /// 附件的文件到了、传的进度变了：还没到的图片换上真图，文件牌重画。
    public func refreshAttachments() { core.refreshAttachments() }

    // MARK: 主题

    private func applyTheme() {
        core.style = theme
        backgroundColor = theme.backgroundColor
        drawsBackground = true
        textContainerInset = NSSize(width: horizontalInset(forWidth: frame.width), height: theme.verticalInset)
        typingAttributes = core.baseAttributes
        core.styleDidChange()
    }

    // MARK: 编辑通知

    public override func didChangeText() {
        super.didChangeText()
        core.flushHighlight()
        // 高贴着字摆的宿主（任务气泡）按它重量高
        invalidateIntrinsicContentSize()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, !hasMarkedText() { onChange?(storedText) }
    }

    /// 换到缩放比例不同的屏：附件的缩略图按新比例重画（见 `ThumbnailLoader`）。
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

    /// 左右留白：至少 `horizontalInset`；有最大行宽时宽出来的部分平分到两边，字居中成一列。
    private func horizontalInset(forWidth width: CGFloat) -> CGFloat {
        guard let maxTextWidth = theme.maxTextWidth else { return theme.horizontalInset }
        return max(theme.horizontalInset, ((width - maxTextWidth) / 2).rounded(.down))
    }

    /// 排完全文、贴着字的高（含上下留白）：不放进滚动视图、高随字长的宿主（任务气泡）按它摆。
    public var fittingHeight: CGFloat {
        let layout = core.layout
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.height + textContainerInset.height * 2)
    }

    // MARK: CueEditorHost

    func resolvedColor(_ color: CueColor) -> CueColor { color }  // 底色在绘制时按当时的外观解析
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

    /// 右键菜单最上面：选中文字时的选区动作（外部提供），再是"插入文件…"，与后面隔一条线。
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

    /// 所有选区变化（键盘、鼠标、程序）都经这里：有没有选区变了就报告。
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let selecting = selectedRange().length > 0
        guard selecting != reportedSelection else { return }
        reportedSelection = selecting
        onSelectionChange?(selecting)
    }

    @objc private func performSelectionAction(_ item: NSMenuItem) {
        guard selectionActions.indices.contains(item.tag), let stored = item.representedObject as? String else { return }
        selectionActions[item.tag].perform(stored)
    }
}
#endif

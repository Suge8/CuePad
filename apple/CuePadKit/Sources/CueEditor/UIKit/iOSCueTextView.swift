#if canImport(UIKit)
import CueText
import UIKit
import UniformTypeIdentifiers

/// TextKit 2 编辑器（iOS/iPadOS 薄宿主）。正文的唯一事实源是 `storedText`（Markdown 原文）：
/// 只有附件（图片与文件牌）在运行时是 U+FFFC，所有出口（保存、复制、通知）都经序列化。
/// 全程不得访问 `UITextView.layoutManager`：一次访问就会把视图永久降级到 TextKit 1。
@MainActor
public final class CueTextView: UITextView, CueEditorHost {
    public let files: any CueFileStore
    /// 设计基准样式；字号会按系统字号档位（Dynamic Type）缩放后使用。
    public var theme: CueEditorTheme { didSet { applyTheme() } }
    /// 用户编辑后的新正文；程序设置 `storedText` 与输入法组合期间不触发。
    public var onChange: ((String) -> Void)?
    /// 有没有选中文字变了（编辑器外的"发送选中""转为任务"据此出现）。
    public var onSelectionChange: ((Bool) -> Void)?
    /// 选中部分的存储格式；没选中为 nil。
    public var selectedStoredText: String? { core.stored(in: selectedRange) }
    /// 选中文字时编辑菜单里排在系统项前面的动作。
    public var selectionActions: [CueSelectionAction] = []
    /// 附件入库失败（磁盘满、文件不可读、太大）。失败的附件不会插入。
    public var onError: ((any Error) -> Void)?
    /// 点了文件牌或还没到这台的图片（键、文件名；图片没有名字）：宿主在本机就打开看，还没到就去 iCloud 取，到了调 `refreshAttachments`。
    /// `picture` 是它的画面在文本视图坐标里的框（文件牌是左边那块缩略图，图片是整张）：全屏页从这里放大出来、缩回这里。
    public var onOpenAttachment: ((_ key: String, _ name: String, _ picture: CGRect) -> Void)?
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

    var pasteboard: UIPasteboard = .general
    private(set) var core: EditorCore!
    private var isLoading = false
    /// 上次报告的"有没有选区"，只在变化时再报。
    var reportedSelection = false
    private var observers: [any NSObjectProtocol] = []
    private var transferDelegate: TransferDelegate?
    private var menuDelegate: MenuDelegate?

    public init(files: any CueFileStore, theme: CueEditorTheme) {
        self.files = files
        self.theme = theme
        let stack = CueTextStack.make()
        super.init(frame: .zero, textContainer: stack.container)
        core = EditorCore(host: self, files: files, style: theme, storage: textStorage, content: stack.content, layout: stack.layout)
        let transfer = TransferDelegate(textView: self)
        transferDelegate = transfer
        pasteDelegate = transfer
        textDropDelegate = transfer
        textDragDelegate = transfer
        let menu = MenuDelegate()
        menuDelegate = menu
        delegate = menu
        configure()
        applyTheme()
        observe()
        // 点附件：只在点中文件牌（或还没到的图片）时才开始，系统定光标、弹键盘的那几个手势要等它不成立才动
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedAttachment(_:)))
        tap.delegate = menu
        addGestureRecognizer(tap)
    }

    /// 附件的文件到了、传的进度变了：还没到的图片换上真图，文件牌重画。
    public func refreshAttachments() { core.refreshAttachments() }

    public required init?(coder: NSCoder) { nil }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configure() {
        allowsEditingTextAttributes = false
        smartDashesType = .no  // 分割线 `---`、`--flag` 不能被替换成破折号
        smartQuotesType = .no
        smartInsertDeleteType = .no
        autocorrectionType = .no
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.image, .plainText, .text, .item].map(\.identifier))
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
    }

    private func observe() {
        let center = NotificationCenter.default
        // 输入法组合期间也要记账；此刻 TextKit 的内容管理器还没同步新文本，位置换算等下一个同步点
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.storageDidProcessEditing() }
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
        get { core.stored() }
        set {
            isLoading = true
            defer { isLoading = false }
            core.load(newValue)
            undoManager?.removeAllActions()
            selectedRange = NSRange(location: 0, length: 0)
        }
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
        result.headingFont = scaled(theme.headingFont, .title2)
        result.title?.font = scaled(theme.title?.font ?? theme.font, .title3)
        return result
    }

    private func applyTheme() {
        let style = scaledStyle()
        core.style = style
        backgroundColor = style.backgroundColor
        textContainerInset = UIEdgeInsets(top: style.verticalInset, left: style.horizontalInset, bottom: style.verticalInset, right: style.horizontalInset)
        typingAttributes = core.baseAttributes
        core.styleDidChange()
    }

    // MARK: 编辑通知

    private func editDidFinish() {
        core.flushHighlight()
        // 组合中的拼音只是标记文本，提交后才是内容，不上报
        if !isLoading, markedTextRange == nil { onChange?(storedText) }
    }

    public override var bounds: CGRect {
        didSet { if bounds.width != oldValue.width { core?.settler.restart() } }
    }

    /// 所有程序性编辑（插图、删图）的唯一入口：替换文本、放置光标、登记撤销（UITextView 不会为直接改 storage 登记撤销），
    /// 并像用户编辑一样发出 `textDidChange`。
    func replace(_ range: NSRange, with replacement: NSAttributedString, caret: Int) {
        let previous = textStorage.attributedSubstring(from: range)
        let previousCaret = selectedRange.location
        let inserted = NSRange(location: range.location, length: replacement.length)
        undoManager?.registerUndo(withTarget: self) { target in
            target.replace(inserted, with: previous, caret: previousCaret)
        }
        textStorage.replaceCharacters(in: range, with: replacement)
        selectedRange = NSRange(location: caret, length: 0)
        typingAttributes = core.baseAttributes
        scrollRangeToVisible(selectedRange)
        NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: self)
        delegate?.textViewDidChange?(self)
    }

    // MARK: 选区

    /// 程序设的选区不经代理的选区回调：在这里也报告。
    public override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = newValue
            reportSelection()
        }
    }

    func reportSelection() {
        let selecting = selectedRange.length > 0
        guard selecting != reportedSelection else { return }
        reportedSelection = selecting
        onSelectionChange?(selecting)
    }

    // MARK: CueEditorHost

    func resolvedColor(_ color: CueColor) -> CueColor { color.resolvedColor(with: traitCollection) }
    /// 单纯 ensureLayout 不会更新 contentSize，要走一次视口布局。
    func layoutDidAdvance() { core.layout.textViewportLayoutController.layoutViewport() }
    func needsRelayout() { setNeedsLayout() }
    var displayScale: CGFloat { traitCollection.displayScale }
}

/// 编辑菜单加上外部提供的选区动作；选区变化（含手势）报告给宿主；点附件的手势只在点中附件时开始，并且先于系统的手势。
private final class MenuDelegate: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let view = gestureRecognizer.view as? CueTextView else { return false }
        return view.opensAttachment(at: gestureRecognizer.location(in: view))
    }

    /// 系统的手势（定光标、成为第一响应者弹键盘）等点附件的手势不成立才动：点在附件上光标不动、键盘不弹。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === gestureRecognizer.view || other.view?.isDescendant(of: gestureRecognizer.view!) == true
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view = textView as? CueTextView, let stored = view.selectedStoredText, !view.selectionActions.isEmpty else { return nil }
        let custom = view.selectionActions.map { action in
            UIAction(title: action.title, image: action.image) { _ in action.perform(stored) }
        }
        return UIMenu(children: custom + suggestedActions)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? CueTextView)?.reportSelection()
    }
}
#endif

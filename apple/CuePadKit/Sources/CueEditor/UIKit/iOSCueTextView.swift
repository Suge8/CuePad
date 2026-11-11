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
    public var onSelectionChange: ((Bool) -> Void)?
    public var selectedStoredText: String? { core.stored(in: selectedRange) }
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

    var pasteboard: UIPasteboard = .general
    private(set) var core: EditorCore!
    private var isLoading = false
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

    private func applyTheme() {
        let style = theme.scaled(for: traitCollection)
        core.style = style
        backgroundColor = style.backgroundColor
        textContainerInset = UIEdgeInsets(top: style.verticalInset, left: style.horizontalInset, bottom: style.verticalInset, right: style.horizontalInset)
        typingAttributes = core.baseAttributes
        core.styleDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

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

    func resolvedColor(_ color: CueColor) -> CueColor { color.resolvedColor(with: traitCollection) }
    /// 单纯 ensureLayout 不会更新 contentSize，要走一次视口布局。
    func layoutDidAdvance() { core.layout.textViewportLayoutController.layoutViewport() }
    func needsRelayout() { setNeedsLayout() }
    var displayScale: CGFloat { traitCollection.displayScale }
}

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

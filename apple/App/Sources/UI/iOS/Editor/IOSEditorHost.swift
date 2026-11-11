#if os(iOS)
import CueEditor
import SwiftUI
import UIKit

final class IOSEditorHandle {
    fileprivate weak var view: CueTextView?
    let spot = AttachmentSpot()
    fileprivate var refocus = false

    var text: String? { view?.storedText }
    var selection: String? { view?.selectedStoredText }
    func insert(_ files: [IncomingFile]) { view?.insert(files) }
    func focus() { view?.becomeFirstResponder() }
    func replace(_ text: String) {
        guard let view else { return }
        let location = view.selectedRange.location
        view.storedText = text
        view.selectedRange = NSRange(location: min(location, (view.text as NSString).length), length: 0)
    }
}

/// 正文只在创建时载入一次，之后编辑器是这张卡正文的唯一写者。
struct IOSEditorHost: UIViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: IOSEditorHandle
    let onChange: (String) -> Void
    /// 都为 nil 时键盘上方只有"收起键盘"。
    var onInsertImage: (() -> Void)?
    var onInsertFile: (() -> Void)?
    var onVariables: (() -> Void)?
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    /// 高贴着字、自己不滚（任务气泡：整张纸一起滚）；否则铺满给的地方、在里面滚（纸页）。
    var fits = false
    var bottomInset: CGFloat = 0
    /// false：盖着别的东西、看不见时（技能与规则文件页标出合并时）收起键盘、不接输入、读屏跳过；回到 true 时之前拿着键盘的再拿回来。
    var editable = true
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview

    func makeCoordinator() -> KeyboardBar.Actions { KeyboardBar.Actions() }

    func makeUIView(context: Context) -> CueTextView {
        let view = CueTextView(files: services.store.files, theme: theme)
        view.storedText = initialText
        context.coordinator.watching = AttachmentLooks.follow(services, in: view)
        view.inputAccessoryView = KeyboardBar(textView: view, actions: context.coordinator, plain: onInsertImage == nil)
        view.accessibilityLabel = String(localized: "正文")
        if fits {
            view.isScrollEnabled = false
            view.alwaysBounceVertical = false
        }
        handle.view = view
        if initialText.isEmpty { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if let range = DebugHooks.preset.editorSelection {
            DebugHooks.later(.milliseconds(500)) {
                view.becomeFirstResponder()
                view.selectedRange = range
            }
        }
        return view
    }

    func updateUIView(_ view: CueTextView, context: Context) {
        // 光标跟随避开的是滚动 inset；只给正文末尾留白，UIKit 输入时仍会把光标推到纸边。
        if view.contentInset.bottom != bottomInset { view.contentInset.bottom = bottomInset }
        view.onChange = onChange
        view.selectionActions = selectionActions
        view.onError = onError
        view.onOpenAttachment = { [weak view, handle, workspace, openPreview] key, name, picture in
            guard let view else { return }
            let frame = picture.offsetBy(dx: -view.contentOffset.x, dy: -view.contentOffset.y)
            handle.spot.open(DraftFile(key: key, name: name), at: frame, in: workspace, with: openPreview)
        }
        context.coordinator.insertImage = onInsertImage ?? {}
        context.coordinator.insertFile = onInsertFile ?? {}
        context.coordinator.variables = onVariables ?? {}
        if view.isEditable != editable { setEditable(view) }
        if view.theme != theme {
            view.theme = theme
        }
    }

    private func setEditable(_ view: CueTextView) {
        if !editable {
            handle.refocus = view.isFirstResponder
            view.resignFirstResponder()
        }
        view.isEditable = editable
        view.isSelectable = editable
        view.isAccessibilityElement = editable
        view.isUserInteractionEnabled = editable
        if editable, handle.refocus { view.becomeFirstResponder() }
    }

    static func dismantleUIView(_ view: CueTextView, coordinator: KeyboardBar.Actions) { coordinator.watching?.cancel() }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CueTextView, context: Context) -> CGSize? {
        guard fits, let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

final class KeyboardBar: UIToolbar {
    private static let itemSize: CGFloat = 44
    /// 随 SwiftUI 更新而替换的动作（工具栏本身只建一次）。也是宿主的协调者：跟着附件传输重画文件牌的任务挂在这里，编辑器拆掉时取消。
    final class Actions {
        var insertImage: () -> Void = {}
        var insertFile: () -> Void = {}
        var variables: () -> Void = {}
        var watching: Task<Void, Never>?
    }

    init(textView: CueTextView, actions: Actions, plain: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.itemSize))
        func item(_ label: String, _ icon: Icon, _ action: @escaping (CueTextView) -> Void) -> UIBarButtonItem {
            let button = UIButton(type: .system, primaryAction: UIAction { [weak textView] _ in
                guard let textView else { return }
                action(textView)
            })
            button.setImage(icon.platformImage, for: .normal)
            button.accessibilityLabel = label
            button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.itemSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.itemSize).isActive = true
            return UIBarButtonItem(customView: button)
        }
        items = (plain ? [] : [
            item(String(localized: "插入图片"), .photo) { _ in actions.insertImage() },
            item(String(localized: "插入文件"), .file) { _ in actions.insertFile() },
            item(String(localized: "变量取值"), .variables) { _ in actions.variables() },
        ]) + [
            .flexibleSpace(),
            item(String(localized: "收起键盘"), .dismissKeyboard) { $0.resignFirstResponder() },
        ]
        sizeToFit()
    }

    required init?(coder: NSCoder) { nil }
}
#endif

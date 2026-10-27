#if os(iOS)
import CueEditor
import SwiftUI
import UIKit

/// 对编辑器的操作口：插入图片、取当前正文与选中部分。
final class IOSEditorHandle {
    fileprivate weak var view: CueTextView?

    var text: String? { view?.storedText }
    /// 选中部分的存储格式；没选中为 nil。
    var selection: String? { view?.selectedStoredText }
    func insertImage(_ data: Data) { view?.insertImage(data: data) }
    func focus() { view?.becomeFirstResponder() }
    /// 换掉整篇正文（说明在 Mac 上被改了、你还没动过，编辑页跟上）：光标留在原来的位置附近。
    func replace(_ text: String) {
        guard let view else { return }
        let location = view.selectedRange.location
        view.storedText = text
        view.selectedRange = NSRange(location: min(location, (view.text as NSString).length), length: 0)
    }
}

/// iOS CueTextView 的 SwiftUI 宿主。正文只在创建时载入一次，之后编辑器是这张卡正文的唯一写者。
struct IOSEditorHost: UIViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: IOSEditorHandle
    let onChange: (String) -> Void
    /// 插图与变量取值；都为 nil 时键盘上方只有"收起键盘"（技能与规则是纯文字，`LibraryFileScreen`）。
    var onInsertImage: (() -> Void)?
    var onVariables: (() -> Void)?
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    /// 高贴着字、自己不滚（任务气泡：整张纸一起滚）；否则铺满给的地方、在里面滚（纸页）。
    var fits = false
    @Environment(AppServices.self) private var services

    func makeCoordinator() -> KeyboardBar.Actions { KeyboardBar.Actions() }

    func makeUIView(context: Context) -> CueTextView {
        let view = CueTextView(imageStore: services.store.files, theme: theme)
        view.storedText = initialText
        view.inputAccessoryView = KeyboardBar(textView: view, actions: context.coordinator, plain: onInsertImage == nil)
        view.accessibilityLabel = String(localized: "正文")
        if fits {
            view.isScrollEnabled = false
            view.alwaysBounceVertical = false
        }
        handle.view = view
        // 新建的空卡直接进入输入
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
        view.onChange = onChange
        view.selectionActions = selectionActions
        view.onError = onError
        context.coordinator.insertImage = onInsertImage ?? {}
        context.coordinator.variables = onVariables ?? {}
        if view.theme.textColor != theme.textColor || view.theme.horizontalInset != theme.horizontalInset || view.theme.title?.color != theme.title?.color {
            view.theme = theme
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CueTextView, context: Context) -> CGSize? {
        guard fits, let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// 键盘上方的工具栏：插图、变量取值、收起键盘。格式就是正文里的 Markdown 原文，没有格式按钮。
final class KeyboardBar: UIToolbar {
    /// 随 SwiftUI 更新而替换的动作（工具栏本身只建一次）：插图与变量由外部弹出选择器与面板。
    final class Actions {
        var insertImage: () -> Void = {}
        var variables: () -> Void = {}
    }

    init(textView: CueTextView, actions: Actions, plain: Bool) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        func item(_ label: String, _ icon: Icon, _ action: @escaping (CueTextView) -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: icon.platformImage, primaryAction: UIAction { [weak textView] _ in
                guard let textView else { return }
                action(textView)
            })
            item.accessibilityLabel = label
            return item
        }
        items = (plain ? [] : [
            item(String(localized: "插入图片"), .photo) { _ in actions.insertImage() },
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

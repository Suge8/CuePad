#if os(iOS)
import CueEditor
import CueText
import SwiftUI
import UIKit

/// 对编辑器的操作口：插入图片、取当前正文与选中部分。
@MainActor
final class IOSEditorHandle {
    fileprivate weak var view: CueTextView?

    var text: String? { view?.storedText }
    /// 选中部分的存储格式；没选中为 nil。
    var selection: String? { view?.selectedStoredText }
    func insertImage(_ data: Data) { view?.insertImage(data: data) }
}

/// iOS CueTextView 的 SwiftUI 宿主。正文只在创建时载入一次，之后编辑器是这张卡正文的唯一写者。
struct IOSEditorHost: UIViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: IOSEditorHandle
    let onChange: (String) -> Void
    let onInsertImage: () -> Void
    let onVariables: () -> Void
    let onSend: () -> Void
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    func makeCoordinator() -> KeyboardBar.Actions { KeyboardBar.Actions() }

    func makeUIView(context: Context) -> CueTextView {
        let view = CueTextView(imageStore: services.images, theme: theme)
        view.storedText = initialText
        view.inputAccessoryView = KeyboardBar(textView: view, actions: context.coordinator)
        view.accessibilityLabel = "正文"
        handle.view = view
        // 新建的空卡直接进入输入
        if initialText.isEmpty { DispatchQueue.main.async { view.becomeFirstResponder() } }
        #if DEBUG
        if let range = DebugScene.editorSelection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                view.becomeFirstResponder()
                view.selectedRange = range
            }
        }
        #endif
        return view
    }

    func updateUIView(_ view: CueTextView, context: Context) {
        view.onChange = onChange
        view.selectionActions = selectionActions
        view.onError = onError
        context.coordinator.send = onSend
        context.coordinator.insertImage = onInsertImage
        context.coordinator.variables = onVariables
        if view.theme.textColor != theme.textColor || view.theme.horizontalInset != theme.horizontalInset { view.theme = theme }
    }
}

/// 键盘上方的工具栏：分割线、插图、变量取值、收起键盘、发送（选中文字时只发选中的部分）。
final class KeyboardBar: UIToolbar {
    /// 随 SwiftUI 更新而替换的动作（工具栏本身只建一次）：插图与变量由外部弹出选择器与面板。
    @MainActor final class Actions {
        var send: () -> Void = {}
        var insertImage: () -> Void = {}
        var variables: () -> Void = {}
    }

    init(textView: CueTextView, actions: Actions) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        func item(_ label: String, _ symbol: String, _ action: @escaping (CueTextView) -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak textView] _ in
                guard let textView else { return }
                action(textView)
            })
            item.accessibilityLabel = label
            return item
        }
        let send = item("发到 Mac", "paperplane.fill") { _ in actions.send() }
        send.style = .prominent
        items = [
            item("插入分割线", "minus") { $0.insertDivider() },
            item("插入图片", "photo") { _ in actions.insertImage() },
            item("变量取值", "curlybraces") { _ in actions.variables() },
            .flexibleSpace(),
            item("收起键盘", "keyboard.chevron.compact.down") { $0.resignFirstResponder() },
            send,
        ]
        sizeToFit()
    }

    required init?(coder: NSCoder) { nil }
}
#endif

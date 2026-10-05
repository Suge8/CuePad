#if os(macOS)
import AppKit
import CueEditor
import CueText
import SwiftUI

/// 对编辑器的操作口：底部操作栏经它插分割线、取当前正文与选中部分。
@MainActor
final class EditorHandle {
    fileprivate weak var view: CueEditorView?

    var text: String? { view?.textView.storedText }
    /// 选中部分的存储格式；没选中为 nil。
    var selection: String? { view?.textView.selectedStoredText }
    func insertDivider() { view?.textView.insertDivider() }
    func focus() { view.map { $0.window?.makeFirstResponder($0.textView) } }
}

/// CueEditorView 的 SwiftUI 宿主。正文只在创建时载入一次：之后编辑器是这张卡正文的唯一写者，
/// Store 回传的自身保存不再灌回编辑器（会打断光标与撤销栈）。
struct EditorHost: NSViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: EditorHandle
    let onChange: (String) -> Void
    var onSelectionChange: (Bool) -> Void = { _ in }
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    func makeNSView(context: Context) -> CueEditorView {
        let view = CueEditorView(imageStore: services.images, theme: theme)
        view.textView.storedText = initialText
        view.scrollerStyle = .overlay
        handle.view = view
        return view
    }

    func updateNSView(_ view: CueEditorView, context: Context) {
        let textView = view.textView
        textView.onChange = onChange
        textView.onSelectionChange = onSelectionChange
        textView.selectionActions = selectionActions
        textView.onError = onError
        if !Self.sameLook(textView.theme, theme) { textView.theme = theme }
    }

    /// 主题每次渲染都新建，只在外观相关的值真的变了才替换（替换会重排全文）。
    private static func sameLook(_ a: CueEditorTheme, _ b: CueEditorTheme) -> Bool {
        a.textColor == b.textColor && a.backgroundColor == b.backgroundColor && a.font == b.font
            && a.horizontalInset == b.horizontalInset && a.variableColor == b.variableColor
    }
}

#endif

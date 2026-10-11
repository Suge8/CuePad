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
    /// 换一张卡就加一：编辑器常驻，`loadKey` 变了把 `initialText` 整体换进现有的编辑器（清空撤销栈、选区回开头、滚到顶），不重建。
    let loadKey: Int
    /// 不可用时不接键盘（纸页收起、编辑器还挂着）。
    let enabled: Bool
    let initialText: String
    let theme: CueEditorTheme
    let handle: EditorHandle
    let onChange: (String) -> Void
    var onSelectionChange: (Bool) -> Void = { _ in }
    var selectionActions: [CueSelectionAction] = []
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    /// 现在编辑器里是哪一次载入的正文。
    final class Coordinator { var loaded = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CueEditorView {
        context.coordinator.loaded = loadKey
        let view = CueEditorView(imageStore: services.store.files, theme: theme)
        view.textView.storedText = initialText
        view.scrollerStyle = .overlay
        handle.view = view
        if let range = DebugHooks.preset.editorSelection {
            DebugHooks.later {
                view.window?.makeFirstResponder(view.textView)
                view.textView.setSelectedRange(range)
            }
        }
        return view
    }

    func updateNSView(_ view: CueEditorView, context: Context) {
        let textView = view.textView
        if context.coordinator.loaded != loadKey {
            context.coordinator.loaded = loadKey
            textView.storedText = initialText
            view.contentView.scroll(to: .zero)
            view.reflectScrolledClipView(view.contentView)
        }
        if textView.acceptsInput != enabled {
            textView.acceptsInput = enabled
            if !enabled, view.window?.firstResponder === textView { view.window?.makeFirstResponder(nil) }
        }
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

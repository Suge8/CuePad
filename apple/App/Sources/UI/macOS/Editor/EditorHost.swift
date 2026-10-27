#if os(macOS)
import AppKit
import CueEditor
import SwiftUI

/// 对编辑器的操作口：底部操作栏经它取当前正文与选中部分。
final class EditorHandle {
    fileprivate weak var textView: CueTextView?

    var text: String? { textView?.storedText }
    /// 选中部分的存储格式；没选中为 nil。
    var selection: String? { textView?.selectedStoredText }
    func focus() {
        if let textView { textView.window?.makeFirstResponder(textView) }
    }
    /// 换掉整篇正文（说明在别处被改了，编辑页跟上）：光标留在原来的位置附近，撤销栈清空（之前的撤销对不上新正文）。
    func replace(_ text: String) {
        guard let textView else { return }
        let location = textView.selectedRange().location
        textView.storedText = text
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
    }
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
    /// ⌘↩ 的主动作（见 `CueTextView.onSubmit`）。
    var onSubmit: (() -> Void)?
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    func makeNSView(context: Context) -> CueEditorView {
        let view = CueEditorView(files: services.store.files, theme: theme)
        view.textView.storedText = initialText
        view.scrollerStyle = .overlay
        handle.textView = view.textView
        if let range = DebugHooks.preset.editorSelection {
            DebugHooks.later {
                view.window?.makeFirstResponder(view.textView)
                view.textView.setSelectedRange(range)
            }
        }
        return view
    }

    func updateNSView(_ view: CueEditorView, context: Context) {
        update(view.textView)
    }

    fileprivate func update(_ textView: CueTextView) {
        textView.onChange = onChange
        textView.onSelectionChange = onSelectionChange
        textView.selectionActions = selectionActions
        textView.onSubmit = onSubmit
        textView.onError = onError
        if !Self.sameLook(textView.theme, theme) { textView.theme = theme }
    }

    /// 主题每次渲染都新建，只在外观相关的值真的变了才替换（替换会重排全文）。
    private static func sameLook(_ a: CueEditorTheme, _ b: CueEditorTheme) -> Bool {
        a.textColor == b.textColor && a.backgroundColor == b.backgroundColor && a.font == b.font
            && a.horizontalInset == b.horizontalInset && a.variableColor == b.variableColor && a.title?.color == b.title?.color
    }
}

/// 不带滚动视图、高贴着字的编辑器（任务气泡：整张纸一起滚，滚轮落在字上也是纸在滚）。其余同 `EditorHost`。
struct FittedEditorHost: NSViewRepresentable {
    let host: EditorHost
    @Environment(AppServices.self) private var services

    func makeNSView(context: Context) -> CueTextView {
        let textView = CueTextView(files: services.store.files, theme: host.theme)
        // 字贴着框的左沿，与气泡里别的行对齐
        textView.textContainer?.lineFragmentPadding = 0
        textView.storedText = host.initialText
        host.handle.textView = textView
        return textView
    }

    func updateNSView(_ textView: CueTextView, context: Context) { host.update(textView) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CueTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        if nsView.frame.width != width { nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height)) }
        return CGSize(width: width, height: nsView.fittingHeight)
    }
}

#endif

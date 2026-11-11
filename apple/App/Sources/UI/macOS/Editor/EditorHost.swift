#if os(macOS)
import AppKit
import CueEditor
import SwiftUI

final class EditorHandle {
    fileprivate weak var textView: CueTextView?
    let spot = AttachmentSpot()
    fileprivate var refocus = false

    var text: String? { textView?.storedText }
    var selection: String? { textView?.selectedStoredText }
    func focus() {
        if let textView { textView.window?.makeFirstResponder(textView) }
    }
    /// 光标留在原来的位置附近，撤销栈清空：之前的撤销对不上新正文。
    func replace(_ text: String) {
        guard let textView else { return }
        let location = textView.selectedRange().location
        textView.storedText = text
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
    }
}

/// 正文只在创建时载入一次：之后编辑器是这张卡正文的唯一写者，Store 回传的自身保存不再灌回编辑器（会打断光标与撤销栈）。
struct EditorHost: NSViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: EditorHandle
    let onChange: (String) -> Void
    var onSelectionChange: (Bool) -> Void = { _ in }
    var selectionActions: [CueSelectionAction] = []
    var onSubmit: (() -> Void)?
    var onError: (any Error) -> Void = { _ in }
    /// false：盖着别的东西、看不见时（技能与规则文件页标出合并时）交出键盘、不接输入、读屏跳过；回到 true 时之前拿着键盘的再拿回来。
    var editable = true
    var bottomInset: CGFloat = 0
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var watching: Task<Void, Never>?
    }

    func makeNSView(context: Context) -> CueEditorView {
        let view = CueEditorView(files: services.store.files, theme: theme)
        view.textView.storedText = initialText
        context.coordinator.watching = AttachmentLooks.follow(services, in: view.textView)
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
        if view.contentInsets.bottom != bottomInset { view.contentInsets.bottom = bottomInset }
        update(view.textView, root: view, workspace: workspace, opener: openPreview)
    }

    static func dismantleNSView(_ view: CueEditorView, coordinator: Coordinator) { coordinator.watching?.cancel() }

    /// 环境里的由真正上屏的那个宿主给（`FittedEditorHost` 里的 `host` 不上屏，读不到环境）。
    fileprivate func update(_ textView: CueTextView, root: NSView, workspace: Workspace, opener: PreviewOpener?) {
        textView.onChange = onChange
        textView.onSelectionChange = onSelectionChange
        textView.selectionActions = selectionActions
        textView.onSubmit = onSubmit
        textView.onError = onError
        textView.onOpenAttachment = { [weak textView, weak root, handle, workspace] key, name, picture in
            guard let textView, let root else { return }
            var frame = root.convert(picture, from: textView)
            if !root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
            handle.spot.open(DraftFile(key: key, name: name), at: frame, in: workspace, with: opener)
        }
        if textView.isEditable != editable { setEditable(textView) }
        if textView.theme != theme { textView.theme = theme }
    }

    private func setEditable(_ textView: CueTextView) {
        let window = textView.window
        if !editable {
            handle.refocus = window?.firstResponder === textView
            if handle.refocus { window?.makeFirstResponder(nil) }
        }
        textView.isEditable = editable
        textView.isSelectable = editable
        textView.setAccessibilityElement(editable)
        if editable, handle.refocus { window?.makeFirstResponder(textView) }
    }
}

struct FittedEditorHost: NSViewRepresentable {
    let host: EditorHost
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview

    func makeCoordinator() -> EditorHost.Coordinator { EditorHost.Coordinator() }

    func makeNSView(context: Context) -> CueTextView {
        let textView = CueTextView(files: services.store.files, theme: host.theme)
        context.coordinator.watching = AttachmentLooks.follow(services, in: textView)
        textView.storedText = host.initialText
        host.handle.textView = textView
        return textView
    }

    func updateNSView(_ textView: CueTextView, context: Context) { host.update(textView, root: textView, workspace: workspace, opener: openPreview) }

    static func dismantleNSView(_ textView: CueTextView, coordinator: EditorHost.Coordinator) { coordinator.watching?.cancel() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CueTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        if nsView.frame.width != width { nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height)) }
        return CGSize(width: width, height: nsView.fittingHeight)
    }
}

#endif

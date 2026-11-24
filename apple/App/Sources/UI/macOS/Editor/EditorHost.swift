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
    func replace(_ text: String) {
        guard let textView else { return }
        let location = textView.selectedRange().location
        textView.storedText = text
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
    }
}

struct EditorHost: NSViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let handle: EditorHandle
    let onChange: (String) -> Void
    var onSelectionChange: (Bool) -> Void = { _ in }
    var selectionActions: [CueSelectionAction] = []
    var onSubmit: (() -> Void)?
    var onError: (any Error) -> Void = { _ in }
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
        if let range = DebugHooks.args.selection {
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
        // 高只由 `sizeThatFits` 定，文本视图不自己改：光标进了标题后面那一行空行，末尾空行的高跟着输入属性变矮几点，
        // 它自己缩高时底边不动（上层不是翻转坐标），标题就往下跳，打第一个字又跳回去
        textView.isVerticallyResizable = false
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

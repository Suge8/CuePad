#if os(macOS)
import AppKit
import CueEditor
import CueText
import SwiftUI

/// 对编辑器的操作口：底部操作栏经它切块、取当前正文。
@MainActor
final class EditorHandle {
    fileprivate weak var view: CueEditorView?

    var text: String? { view?.textView.storedText }
    func insertSplit() { view?.textView.insertSplit() }
    func focus() { view.map { $0.window?.makeFirstResponder($0.textView) } }
}

/// CueEditorView 的 SwiftUI 宿主。正文只在创建时载入一次：之后编辑器是这张卡正文的唯一写者，
/// Store 回传的自身保存不再灌回编辑器（会打断光标与撤销栈）。
struct EditorHost: NSViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let numbering: CueNumbering
    let handle: EditorHandle
    let onChange: (String) -> Void
    var onBlockAction: (CueBlockAction) -> Void = { _ in }
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    func makeNSView(context: Context) -> CueEditorView {
        let view = CueEditorView(imageStore: services.images, theme: theme)
        view.textView.storedText = initialText
        view.textView.numbering = numbering
        view.scrollerStyle = .overlay
        handle.view = view
        DispatchQueue.main.async { handle.focus() }
        return view
    }

    func updateNSView(_ view: CueEditorView, context: Context) {
        let textView = view.textView
        textView.onChange = onChange
        textView.onBlockAction = onBlockAction
        textView.onError = onError
        if textView.numbering != numbering { textView.numbering = numbering }
        if !Self.sameLook(textView.theme, theme) { textView.theme = theme }
    }

    /// 主题每次渲染都新建，只在外观相关的值真的变了才替换（替换会重排全文）。
    private static func sameLook(_ a: CueEditorTheme, _ b: CueEditorTheme) -> Bool {
        a.textColor == b.textColor && a.backgroundColor == b.backgroundColor && a.font == b.font
            && a.horizontalInset == b.horizontalInset && a.variableColor == b.variableColor
    }
}

/// 编辑中的正文自动保存：停手一小会儿后写入，离开页面时立即写入未保存的部分。
@MainActor
final class Autosave {
    private static let delay: Duration = .milliseconds(400)

    private let save: (String) async throws -> Void
    private let onError: (any Error) -> Void
    private var pending: String?
    private var timer: Task<Void, Never>?

    init(save: @escaping (String) async throws -> Void, onError: @escaping (any Error) -> Void) {
        self.save = save
        self.onError = onError
    }

    func changed(_ text: String) {
        pending = text
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        guard let text = pending else { return }
        pending = nil
        timer?.cancel()
        do { try await save(text) } catch { onError(error) }
    }
}
#endif

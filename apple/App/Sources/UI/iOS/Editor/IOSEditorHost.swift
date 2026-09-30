#if os(iOS)
import CueEditor
import CueText
import SwiftUI
import UIKit

/// 对编辑器的操作口：插入图片、取当前正文。
@MainActor
final class IOSEditorHandle {
    fileprivate weak var view: CueTextView?

    var text: String? { view?.storedText }
    func insertImage(_ data: Data) { view?.insertImage(data: data) }
}

/// iOS CueTextView 的 SwiftUI 宿主。正文只在创建时载入一次，之后编辑器是这张卡正文的唯一写者。
struct IOSEditorHost: UIViewRepresentable {
    let initialText: String
    let theme: CueEditorTheme
    let numbering: CueNumbering
    let handle: IOSEditorHandle
    let onChange: (String) -> Void
    let onInsertImage: () -> Void
    let onVariables: () -> Void
    var onBlockAction: (CueBlockAction) -> Void = { _ in }
    var onError: (any Error) -> Void = { _ in }
    @Environment(AppServices.self) private var services

    func makeUIView(context: Context) -> CueTextView {
        let view = CueTextView(imageStore: services.images, theme: theme)
        view.storedText = initialText
        view.numbering = numbering
        handle.view = view
        // 新建的空卡直接进入输入
        if initialText.isEmpty { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: CueTextView, context: Context) {
        view.onChange = onChange
        view.onInsertImageRequest = onInsertImage
        view.onVariablesRequest = onVariables
        view.onBlockAction = onBlockAction
        view.onError = onError
        if view.numbering != numbering { view.numbering = numbering }
        if view.theme.textColor != theme.textColor || view.theme.horizontalInset != theme.horizontalInset { view.theme = theme }
    }
}
#endif

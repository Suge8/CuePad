#if canImport(AppKit)
import AppKit

/// 可直接放进窗口或 SwiftUI（NSViewRepresentable）的编辑器：滚动视图 + `CueTextView`。
@MainActor
public final class CueEditorView: NSScrollView {
    public let textView: CueTextView

    public init(imageStore: any CueImageStore, theme: CueEditorTheme = .neutral) {
        textView = CueTextView(imageStore: imageStore, theme: theme)
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        documentView = textView
    }

    public required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        // 文本视图至少铺满可视区，点击文末空白处也能定位光标
        textView.minSize = NSSize(width: 0, height: contentSize.height)
    }
}
#endif

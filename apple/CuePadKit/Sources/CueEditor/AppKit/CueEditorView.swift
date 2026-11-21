#if canImport(AppKit)
import AppKit

@MainActor
public final class CueEditorView: NSScrollView {
    public let textView: CueTextView

    public init(files: any CueFileStore, theme: CueEditorTheme) {
        textView = CueTextView(files: files, theme: theme)
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        documentView = textView
    }

    public required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        textView.minSize = NSSize(width: 0, height: contentSize.height)
    }
}
#endif

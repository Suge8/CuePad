#if canImport(AppKit)
import AppKit

/// 分割线：一条横贯的细虚线。
@MainActor
final class CueDividerView: NSView {
    private unowned let attachment: CueDividerAttachment

    private var theme: CueEditorTheme { attachment.core?.style ?? .neutral }

    init(attachment: CueDividerAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("分割线")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        theme.dividerColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.midY))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1
        line.stroke()
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// 分割线：一条横贯的细虚线。
@MainActor
final class CueDividerView: UIView {
    private unowned let attachment: CueDividerAttachment

    private var style: CueEditorTheme { attachment.core?.style ?? .neutral }

    init(attachment: CueDividerAttachment) {
        self.attachment = attachment
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "分割线"
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        style.dividerColor.setStroke()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: 0, y: bounds.midY))
        line.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1
        line.stroke()
    }
}
#endif

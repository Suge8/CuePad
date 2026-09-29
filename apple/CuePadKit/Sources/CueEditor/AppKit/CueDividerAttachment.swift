#if canImport(AppKit)
import AppKit

/// 分隔线附件：不可编辑控件，自带编号标签与复制/发送按钮。
final class CueDividerAttachment: NSTextAttachment {
    weak var owner: CueTextView?
    weak var view: CueDividerView?
    var label = ""

    init() { super.init(data: nil, ofType: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewProvider(
        for parentView: NSView?, location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = CueDividerViewProvider(
            textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

final class CueDividerViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        nonisolated(unsafe) let attachment = textAttachment as! CueDividerAttachment
        view = MainActor.assumeIsolated {
            let divider = CueDividerView(attachment: attachment)
            attachment.view = divider
            return divider
        }
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        nonisolated(unsafe) let attachment = textAttachment as! CueDividerAttachment
        let height = MainActor.assumeIsolated { attachment.owner?.theme.dividerHeight ?? 28 }
        return CGRect(x: 0, y: -height / 4, width: max(proposedLineFragment.width, 1), height: height)
    }
}

@MainActor
final class CueDividerView: NSView {
    private unowned let attachment: CueDividerAttachment
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)

    var labelText: String {
        didSet {
            setAccessibilityLabel(labelText.isEmpty ? "分块" : "分块 \(labelText)")
            needsDisplay = true
        }
    }

    private var theme: CueEditorTheme { attachment.owner?.theme ?? .neutral }

    init(attachment: CueDividerAttachment) {
        self.attachment = attachment
        labelText = attachment.label
        super.init(frame: .zero)
        for (button, kind) in [(copyButton, CueBlockActionKind.copy), (sendButton, .send)] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.target = self
            button.action = kind == .copy ? #selector(copyTapped) : #selector(sendTapped)
            button.setAccessibilityLabel(kind == .copy ? "复制本块" : "发送本块")
            addSubview(button)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(labelText.isEmpty ? "分块" : "分块 \(labelText)")
    }

    required init?(coder: NSCoder) { nil }

    @objc private func copyTapped() { attachment.owner?.performDividerAction(.copy, from: attachment) }
    @objc private func sendTapped() { attachment.owner?.performDividerAction(.send, from: attachment) }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.dividerLabelColor]
    }

    private var labelWidth: CGFloat {
        labelText.isEmpty ? 0 : (labelText as NSString).size(withAttributes: labelAttributes).width + 8
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 44, height: 20)
        sendButton.frame = NSRect(origin: NSPoint(x: bounds.width - size.width, y: (bounds.height - size.height) / 2), size: size)
        copyButton.frame = sendButton.frame.offsetBy(dx: -size.width - 6, dy: 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        var startX: CGFloat = 0
        if !labelText.isEmpty {
            let text = labelText as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: NSPoint(x: 0, y: midY - size.height / 2), withAttributes: labelAttributes)
            startX = labelWidth
        }
        let endX = copyButton.frame.minX - 8
        guard endX > startX else { return }
        theme.dividerColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: startX, y: midY))
        line.line(to: NSPoint(x: endX, y: midY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1
        line.stroke()
    }
}
#endif

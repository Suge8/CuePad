#if canImport(UIKit)
import UIKit

/// 分隔线附件：不可编辑控件，自带编号标签与复制/发送按钮。
final class CueDividerAttachment: NSTextAttachment {
    weak var owner: CueTextView?
    weak var view: CueDividerView?
    var label = ""

    init() { super.init(data: nil, ofType: nil) }
    required init?(coder: NSCoder) { nil }

    override func viewProvider(
        for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?
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
        let height = MainActor.assumeIsolated { attachment.owner?.style.dividerHeight ?? 32 }
        return CGRect(x: 0, y: -height / 4, width: max(proposedLineFragment.width, 1), height: height)
    }
}

@MainActor
final class CueDividerView: UIView {
    private unowned let attachment: CueDividerAttachment
    private let copyButton = UIButton(configuration: .gray())
    private let sendButton = UIButton(configuration: .gray())

    var labelText: String {
        didSet {
            accessibilityLabel = labelText.isEmpty ? "分块" : "分块 \(labelText)"
            setNeedsDisplay()
        }
    }

    private var style: CueEditorTheme { attachment.owner?.style ?? .neutral }

    init(attachment: CueDividerAttachment) {
        self.attachment = attachment
        labelText = attachment.label
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityLabel = labelText.isEmpty ? "分块" : "分块 \(labelText)"
        configure(copyButton, title: "复制", label: "复制本块", kind: .copy)
        configure(sendButton, title: "发送", label: "发送本块", kind: .send)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ button: UIButton, title: String, label: String, kind: CueBlockActionKind) {
        button.configuration?.title = title
        button.configuration?.buttonSize = .small
        button.configuration?.cornerStyle = .capsule
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            attachment.owner?.performDividerAction(kind, from: attachment)
        }, for: .primaryActionTriggered)
        addSubview(button)
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: style.dividerLabelColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let send = sendButton.sizeThatFits(bounds.size)
        let copy = copyButton.sizeThatFits(bounds.size)
        sendButton.frame = CGRect(x: bounds.width - send.width, y: (bounds.height - send.height) / 2, width: send.width, height: send.height)
        copyButton.frame = CGRect(x: sendButton.frame.minX - 8 - copy.width, y: (bounds.height - copy.height) / 2, width: copy.width, height: copy.height)
    }

    override func draw(_ rect: CGRect) {
        let midY = bounds.midY
        var startX: CGFloat = 0
        if !labelText.isEmpty {
            let text = labelText as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: CGPoint(x: 0, y: midY - size.height / 2), withAttributes: labelAttributes)
            startX = size.width + 8
        }
        let endX = copyButton.frame.minX - 8
        guard endX > startX else { return }
        style.dividerColor.setStroke()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: startX, y: midY))
        line.addLine(to: CGPoint(x: endX, y: midY))
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1
        line.stroke()
    }
}
#endif

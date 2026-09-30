#if canImport(AppKit)
import AppKit

/// 附件图像的像素渲染（macOS）。
enum CueImageRendering {
    static let stub = NSImage(size: NSSize(width: 1, height: 1))

    static func thumbnail(_ thumbnail: CGImage, size: CGSize, cornerRadius: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
            NSGraphicsContext.current?.cgContext.draw(thumbnail, in: rect)
            return true
        }
    }

    static func placeholder(size: CGSize, style: CueEditorTheme, missing: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            style.placeholderColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: style.imageCornerRadius, yRadius: style.imageCornerRadius).fill()
            if missing {
                let label = "图片缺失" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: style.dividerLabelColor]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
    }
}
#endif

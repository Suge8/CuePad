#if canImport(AppKit)
import AppKit

/// 附件图像的像素渲染（macOS）。
enum CueImageRendering {
    static let stub = NSImage(size: NSSize(width: 1, height: 1))

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> NSImage {
        NSImage(cgImage: pixels, size: size)
    }

    static func placeholder(size: CGSize, style: CueEditorTheme, missing: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            style.placeholderColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: style.imageCornerRadius, yRadius: style.imageCornerRadius).fill()
            if missing {
                let label = "图片缺失" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: style.markerColor]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
    }
}
#endif

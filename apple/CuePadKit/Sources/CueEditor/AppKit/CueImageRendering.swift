#if canImport(AppKit)
import AppKit

/// 附件图像的像素渲染（macOS）。
enum CueImageRendering {
    static let stub = NSImage(size: NSSize(width: 1, height: 1))

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> NSImage {
        NSImage(cgImage: pixels, size: size)
    }

    /// 分割线：一条横贯的细虚线，画在图的垂直中线上。
    static func divider(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.setStroke()
            let line = NSBezierPath()
            let y = rect.midY.rounded(.down) + 0.5  // 1pt 线落在整点行上，不被两行像素各吃一半
            line.move(to: NSPoint(x: 0, y: y))
            line.line(to: NSPoint(x: rect.maxX, y: y))
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.lineWidth = 1
            line.stroke()
            return true
        }
        image.accessibilityDescription = "分割线"
        return image
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

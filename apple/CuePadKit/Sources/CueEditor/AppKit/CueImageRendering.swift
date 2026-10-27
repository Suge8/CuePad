#if canImport(AppKit)
import AppKit

enum CueImageRendering {
    static let stub = NSImage(size: NSSize(width: 1, height: 1))

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> NSImage {
        NSImage(cgImage: pixels, size: size)
    }

    /// 图片的占位：底色圆角块；`label` 写在中间（还没到这台的图片怎么取、传了几成）。
    static func placeholder(size: CGSize, style: CueEditorTheme, label: String?) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            style.imagePlaceholderColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: style.imageCornerRadius, yRadius: style.imageCornerRadius).fill()
            if let label = label as NSString? {
                let attributes: [NSAttributedString.Key: Any] = [.font: style.captionFont, .foregroundColor: style.markerColor]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
    }

    /// 左上为原点的画布（文件牌）。画在绘制的那一刻现跑，颜色按当时的外观解析。
    static func canvas(size: CGSize, draw: @escaping @MainActor (CGContext) -> Void) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            MainActor.assumeIsolated { draw(context) }
            return true
        }
    }

    /// 文件牌上没有缩略图时的记号（宿主给的符号）按颜色着色。
    static func tinted(_ symbol: NSImage, color: NSColor, size: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        return symbol.withSymbolConfiguration(config) ?? symbol
    }
}
#endif

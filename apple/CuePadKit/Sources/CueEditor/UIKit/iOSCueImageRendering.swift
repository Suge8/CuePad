#if canImport(UIKit)
import UIKit

enum CueImageRendering {
    static let stub = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> UIImage {
        UIImage(cgImage: pixels, scale: CGFloat(pixels.width) / max(size.width, 1), orientation: .up)
    }

    /// 图片的占位：底色圆角块；`label` 写在中间（还没到这台的图片怎么取、传了几成）。
    static func placeholder(size: CGSize, style: CueEditorTheme, label: String?) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            style.imagePlaceholderColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: style.imageCornerRadius).fill()
            guard let label = label as NSString? else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: style.markerColor]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    /// 左上为原点的画布（文件牌）。动态色由调用方先按当前外观解析。
    static func canvas(size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { draw($0.cgContext) }
    }

    /// 文件牌上没有缩略图时的记号（宿主给的符号）按颜色着色。
    static func tinted(_ symbol: UIImage, color: UIColor) -> UIImage {
        (symbol.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)) ?? symbol)
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }
}
#endif

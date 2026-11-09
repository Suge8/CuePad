#if canImport(UIKit)
import UIKit

enum CueImageRendering {
    static let stub = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    static func image(_ pixels: CGImage, size: CGSize) -> UIImage {
        UIImage(cgImage: pixels, scale: CGFloat(pixels.width) / max(size.width, 1), orientation: .up)
    }

    static func placeholder(size: CGSize, style: CueEditorTheme, label: String?) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            style.imagePlaceholderColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: style.imageCornerRadius).fill()
            guard let label = label as NSString? else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: style.captionFont, .foregroundColor: style.markerColor]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }

    /// 动态色由调用方先按当前外观解析。
    static func canvas(size: CGSize, draw: (CGContext) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { draw($0.cgContext) }
    }

    static func tinted(_ symbol: UIImage, color: UIColor, size: CGFloat) -> UIImage {
        (symbol.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .regular)) ?? symbol)
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }
}
#endif

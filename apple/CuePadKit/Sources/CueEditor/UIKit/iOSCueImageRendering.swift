#if canImport(UIKit)
import UIKit

enum CueImageRendering {
    static let stub = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> UIImage {
        UIImage(cgImage: pixels, scale: CGFloat(pixels.width) / max(size.width, 1), orientation: .up)
    }

    static func placeholder(size: CGSize, style: CueEditorTheme, missing: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            style.imagePlaceholderColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: style.imageCornerRadius).fill()
            guard missing else { return }
            let label = String(localized: "图片缺失") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: style.markerColor]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }
}
#endif

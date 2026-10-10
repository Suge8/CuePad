#if canImport(UIKit)
import UIKit

/// 附件图像的像素渲染（iOS）。
enum CueImageRendering {
    static let stub = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// 已按像素画好的位图（`RoundedThumbnail`）包成图片，按点尺寸显示。
    static func image(_ pixels: CGImage, size: CGSize) -> UIImage {
        UIImage(cgImage: pixels, scale: CGFloat(pixels.width) / max(size.width, 1), orientation: .up)
    }

    /// 分割线：一条横贯的细虚线，画在图的垂直中线上。
    static func divider(size: CGSize, color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            color.setStroke()
            let line = UIBezierPath()
            let y = (size.height / 2).rounded(.down) + 0.5  // 1pt 线落在整点行上，不被两行像素各吃一半
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            line.setLineDash([4, 3], count: 2, phase: 0)
            line.lineWidth = 1
            line.stroke()
        }
    }

    static func placeholder(size: CGSize, style: CueEditorTheme, missing: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            style.placeholderColor.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: style.imageCornerRadius).fill()
            guard missing else { return }
            let label = "图片缺失" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: style.dividerLabelColor]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }
    }
}
#endif

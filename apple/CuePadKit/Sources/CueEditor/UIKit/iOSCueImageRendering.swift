#if canImport(UIKit)
import UIKit

/// 附件图像的像素渲染（iOS）。
enum CueImageRendering {
    static let stub = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    static func thumbnail(_ thumbnail: CGImage, size: CGSize, cornerRadius: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
            UIImage(cgImage: thumbnail).draw(in: rect)
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

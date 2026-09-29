#if canImport(UIKit)
import UIKit

/// 按需提供附件要画的图：缩略图已解码就直接画；否则先画占位并在后台降采样，完成后请求重绘。
/// 解码只发生在附件被绘制时，视口外的图片不会被读取。
@MainActor
final class ThumbnailLoader {
    private unowned let textView: CueTextView
    private var inFlight = Set<URL>()
    private var failed = Set<URL>()
    private let rendered = NSCache<NSString, UIImage>()

    init(textView: CueTextView) { self.textView = textView }

    func image(at url: URL?, size: CGSize) -> UIImage {
        guard let url, !failed.contains(url) else { return placeholder(size, missing: true) }
        guard let thumbnail = ImageLoading.cachedThumbnail(at: url) else {
            decode(url)
            return placeholder(size, missing: false)
        }
        let key = "\(url.path)@\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = rendered.object(forKey: key) { return cached }
        let radius = textView.style.imageCornerRadius
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            UIImage(cgImage: thumbnail).draw(in: rect)
        }
        rendered.setObject(image, forKey: key)
        return image
    }

    private func decode(_ url: URL) {
        guard inFlight.insert(url).inserted else { return }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { ImageLoading.thumbnail(at: url) }.value
            guard let self else { return }
            inFlight.remove(url)
            if decoded == nil { failed.insert(url) }
            textView.redrawImages(at: url)
        }
    }

    private func placeholder(_ size: CGSize, missing: Bool) -> UIImage {
        let style = textView.style
        return UIGraphicsImageRenderer(size: size).image { _ in
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

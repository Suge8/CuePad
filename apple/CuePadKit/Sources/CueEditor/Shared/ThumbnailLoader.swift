import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 按需提供附件要画的图：缩略图已解码就直接画；否则先画占位并在后台降采样，完成后请求重绘。
/// 解码只发生在附件被绘制时，视口外的图片不会被读取。像素渲染（圆角、占位）是平台差异，见 `CueImageRendering`。
@MainActor
final class ThumbnailLoader {
    private unowned let core: EditorCore
    private var inFlight = Set<URL>()
    private var failed = Set<URL>()
    private let rendered = NSCache<NSString, CueImage>()

    init(core: EditorCore) { self.core = core }

    func image(at url: URL?, size: CGSize) -> CueImage {
        guard let url, !failed.contains(url) else { return CueImageRendering.placeholder(size: size, style: core.style, missing: true) }
        guard let thumbnail = Thumbnails.cached(at: url, maxPixel: ImageLoading.maxThumbnailPixel) else {
            decode(url)
            return CueImageRendering.placeholder(size: size, style: core.style, missing: false)
        }
        let key = "\(url.path)@\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = rendered.object(forKey: key) { return cached }
        let image = CueImageRendering.thumbnail(thumbnail, size: size, cornerRadius: core.style.imageCornerRadius)
        rendered.setObject(image, forKey: key)
        return image
    }

    private func decode(_ url: URL) {
        guard inFlight.insert(url).inserted else { return }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) { Thumbnails.image(at: url, maxPixel: ImageLoading.maxThumbnailPixel) }.value
            guard let self else { return }
            inFlight.remove(url)
            if decoded == nil { failed.insert(url) }
            core.redrawImages(at: url)
        }
    }
}

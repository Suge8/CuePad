import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 按需提供附件要画的图：后台降采样、按显示尺寸画好圆角，主线程只贴现成的位图；没画好之前画占位，好了请求重绘。
/// 解码只发生在附件被绘制时，视口外的图片不会被读取。尺寸或屏幕缩放比例变了（拖窗口、移到另一块屏）先沿用这张图上一份画好的，
/// 按新的尺寸与比例在后台重画，不闪占位。
@MainActor
final class ThumbnailLoader {
    private unowned let core: EditorCore
    private var inFlight = Set<NSString>()
    private var failed = Set<URL>()
    private let rendered = NSCache<NSString, CueImage>()
    private var latest: [URL: CueImage] = [:]

    init(core: EditorCore) { self.core = core }

    func image(at url: URL?, size: CGSize) -> CueImage {
        guard let url, !failed.contains(url) else { return CueImageRendering.placeholder(size: size, style: core.style, missing: true) }
        let scale = core.displayScale
        let key = "\(url.path)@\(Int(size.width))x\(Int(size.height))@\(scale)x" as NSString
        if let cached = rendered.object(forKey: key) { return cached }
        render(url, size: size, scale: scale, key: key)
        return latest[url] ?? CueImageRendering.placeholder(size: size, style: core.style, missing: false)
    }

    private func render(_ url: URL, size: CGSize, scale: CGFloat, key: NSString) {
        guard inFlight.insert(key).inserted else { return }
        let radius = core.style.imageCornerRadius
        Task { [weak self] in
            let pixels = await Task.detached(priority: .userInitiated) {
                Thumbnails.image(at: url, maxPixel: ImageLoading.maxThumbnailPixel)
                    .flatMap { RoundedThumbnail.render($0, size: size, cornerRadius: radius, scale: scale) }
            }.value
            guard let self else { return }
            inFlight.remove(key)
            if let pixels {
                let image = CueImageRendering.image(pixels, size: size)
                rendered.setObject(image, forKey: key)
                latest[url] = image
            } else {
                failed.insert(url)
            }
            core.redrawImages(at: url)
        }
    }
}

/// 缩略图按显示的像素尺寸画成圆角位图（在后台调用）：主线程每次绘制只是贴图，不再缩放大图、裁圆角。
nonisolated enum RoundedThumbnail {
    static func render(_ image: CGImage, size: CGSize, cornerRadius: CGFloat, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius * scale, cornerHeight: cornerRadius * scale, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

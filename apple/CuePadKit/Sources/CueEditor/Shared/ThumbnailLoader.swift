import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 按需提供附件要画的图，两种附件一套：内联图片按显示尺寸后台降采样、画好圆角（`image`），文件牌左边是系统快速查看的缩略图（`chip`）。
/// 主线程只贴现成的位图；没画好之前画占位，好了请求重画这个键的附件。只在附件被绘制（进入视口）时才要，视口外的文件不读。
/// 尺寸或屏幕缩放比例变了（拖窗口、移到另一块屏）先沿用这张图上一份画好的，按新的尺寸与比例在后台重画，不闪占位。
@MainActor
final class ThumbnailLoader {
    private unowned let core: EditorCore
    private var inFlight = Set<NSString>()
    /// 出不了的（按文件，不按尺寸）：不再试。图片画"图片缺失"，文件牌画类型记号。
    private var failed = Set<NSString>()
    private let rendered = NSCache<NSString, CueImage>()
    private let chips = NSCache<NSString, CGImage>()
    private var latest: [URL: CueImage] = [:]

    nonisolated private static let maxPixel = 1600

    init(core: EditorCore) { self.core = core }

    func image(key: String, at url: URL, size: CGSize) -> CueImage {
        guard !failed.contains(url.path as NSString) else {
            return CueImageRendering.placeholder(size: size, style: core.style, label: String(localized: "图片缺失"))
        }
        let scale = core.displayScale, radius = core.style.imageCornerRadius
        let id = "\(url.path)@\(Int(size.width))x\(Int(size.height))@\(scale)x" as NSString
        if let cached = rendered.object(forKey: id) { return cached }
        load(id, failing: url.path as NSString, redrawing: key) {
            await Self.pixels(at: url, size: size, cornerRadius: radius, scale: scale)
        } done: { [weak self] pixels in
            let image = CueImageRendering.image(pixels, size: size)
            self?.rendered.setObject(image, forKey: id)
            self?.latest[url] = image
        }
        return latest[url] ?? CueImageRendering.placeholder(size: size, style: core.style, label: nil)
    }

    /// 文件牌左边的缩略图；还没出好或出不了为 nil（此时开始出，牌子先画类型记号）。
    func chip(key: String, at url: URL) -> CGImage? {
        let scale = core.displayScale
        let id = "\(url.path)@chip@\(scale)x" as NSString
        if let cached = chips.object(forKey: id) { return cached }
        guard !failed.contains(id) else { return nil }
        load(id, failing: id, redrawing: key) {
            await Thumbnails.chip(at: url, side: FileChip.thumbSide, scale: scale)
        } done: { [weak self] image in
            self?.chips.setObject(image, forKey: id)
        }
        return nil
    }

    private func load(
        _ id: NSString, failing: NSString, redrawing key: String, make: @escaping @Sendable () async -> CGImage?,
        done: @escaping @MainActor (CGImage) -> Void
    ) {
        guard inFlight.insert(id).inserted else { return }
        Task(priority: .userInitiated) { [weak self] in
            let image = await make()
            guard let self else { return }
            inFlight.remove(id)
            if let image { done(image) } else { failed.insert(failing) }
            core.redraw(key: key)
        }
    }

    @concurrent private static func pixels(at url: URL, size: CGSize, cornerRadius: CGFloat, scale: CGFloat) async -> CGImage? {
        Thumbnails.image(at: url, maxPixel: Self.maxPixel)
            .flatMap { RoundedThumbnail.render($0, size: size, cornerRadius: cornerRadius, scale: scale) }
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

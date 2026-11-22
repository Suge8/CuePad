import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

public enum Thumbnails {
    public static func image(at url: URL, maxPixel: Int) -> CGImage? {
        let key = key(url, maxPixel)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = source(url).flatMap({ downsample($0, maxPixel: maxPixel) }) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    public static func decoded(at url: URL, longestSide: (CGSize) -> Int) -> CGImage? {
        source(url).flatMap { downsample($0, longestSide: longestSide) }
    }

    public static func decoded(_ data: Data, longestSide: (CGSize) -> Int) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, options).flatMap { downsample($0, longestSide: longestSide) }
    }

    private static var options: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    private static func source(_ url: URL) -> CGImageSource? { CGImageSourceCreateWithURL(url as CFURL, options) }

    /// 编辑器里图片的点尺寸，只读文件头：按图片自带 DPI 折算（截图 144dpi → 像素的一半），计入方向标记（全屏页也用它取图的真实比例）。
    public static func pointSize(at url: URL) -> CGSize? {
        guard let header = source(url).flatMap(header) else { return nil }
        func dpi(_ key: CFString) -> Double { (header.props[key] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil } ?? 72 }
        let size = CGSize(width: header.pixels.width * 72 / dpi(kCGImagePropertyDPIWidth), height: header.pixels.height * 72 / dpi(kCGImagePropertyDPIHeight))
        return header.turned ? CGSize(width: size.height, height: size.width) : size
    }

    public static func pixelSize(at url: URL) -> CGSize? {
        guard let header = source(url).flatMap(header) else { return nil }
        return header.turned ? CGSize(width: header.pixels.height, height: header.pixels.width) : header.pixels
    }

    private static func header(_ source: CGImageSource) -> (props: [CFString: Any], pixels: CGSize, turned: Bool)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (props, CGSize(width: width, height: height), (5...8).contains(orientation))
    }

    private static func downsample(_ source: CGImageSource, longestSide: (CGSize) -> Int) -> CGImage? {
        guard let header = header(source) else { return nil }
        let size = header.pixels
        return downsample(source, maxPixel: longestSide(header.turned ? CGSize(width: size.height, height: size.width) : size))
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// 系统快速查看的缩略图，整张放进 `fitting`（像素）；`icons` 时出不了画面的给类型图标。系统不一定照要的尺寸给
    /// （视频常按原片给），要多大的由调用方再 `shrunk`。
    public static func system(at url: URL, fitting pixels: CGSize, scale: CGFloat, icons: Bool) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: pixels.width / scale, height: pixels.height / scale), scale: scale,
            representationTypes: icons ? .all : .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    @concurrent public static func chip(at url: URL, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard let image = await system(at: url, fitting: CGSize(width: pixels, height: pixels), scale: scale, icons: true) else { return nil }
        return await shrunk(image, to: pixels)
    }

    /// 超过 `longest`（像素）的重画到这个最长边，原图随即放掉：系统缩略图按原片给时一张约 11MB，画上屏时还要再拷一份。
    @concurrent public static func shrunk(_ image: CGImage, to longest: Int) async -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard max(image.width, image.height) > longest else { return image }
        let factor = CGFloat(longest) / max(size.width, size.height)
        let width = max(1, Int((size.width * factor).rounded())), height = max(1, Int((size.height * factor).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)@\(maxPixel)" as NSString }

    /// 各线程都来取（后台降采样）。NSCache 自带锁、文档写明可跨线程增删查不另加锁，取出的 CGImage 不可变；
    /// SDK 却把 NSCache 标成不能 Sendable（子类补的 `@unchecked Sendable` 也不认），换成 `Mutex` 又要把不是 Sendable 的 CGImage 送出锁外。
    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
}

import CoreGraphics
import Foundation
import ImageIO

/// 编辑器里的图片尺寸：只读文件头。
enum ImageLoading {
    static let maxThumbnailPixel = 1600
    private static let fallbackDPI = 72.0

    /// 按图片自带 DPI 折算的点尺寸（截图 144dpi → 像素的一半），计入方向标记。
    static func pointSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }
        let dpiX = positive(props[kCGImagePropertyDPIWidth]) ?? fallbackDPI
        let dpiY = positive(props[kCGImagePropertyDPIHeight]) ?? fallbackDPI
        let size = CGSize(width: pixelWidth * fallbackDPI / dpiX, height: pixelHeight * fallbackDPI / dpiY)
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }

    private static func positive(_ value: Any?) -> Double? {
        (value as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// 缩略图：ImageIO 直接降采样解码（已按 EXIF 方向校正、不放大），原图不整张进内存。编辑器与卡片墙共用这一份，
/// 解码结果按"文件 + 尺寸"缓存；系统内存紧张时 NSCache 自动清空，下次需要时重新降采样。
public enum Thumbnails {
    /// 已解码的缩略图；不触发解码，可在主线程调用。
    public static func cached(at url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// 最长边不超过 `maxPixel` 的缩略图；未缓存时同步解码（在后台调用）。不是图片或读不到返回 nil。
    public static func image(at url: URL, maxPixel: Int) -> CGImage? {
        let key = key(url, maxPixel)
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// 原图的像素尺寸（计入方向标记）：只读文件头，不解码。读不到为 nil。
    public static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(url.path)@\(maxPixel)" as NSString }

    private static let cache: ImageCache = {
        let cache = ImageCache()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
}

private final class ImageCache: NSCache<NSString, CGImage>, @unchecked Sendable {}

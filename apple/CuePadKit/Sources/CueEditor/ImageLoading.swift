import CoreGraphics
import Foundation
import ImageIO
import os

/// 图片读取：尺寸只读文件头，缩略图用 ImageIO 直接降采样解码，原图从不整张进内存。
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

    /// 已解码的缩略图（不触发解码）。
    static func cachedThumbnail(at url: URL) -> CGImage? {
        ThumbnailCache.shared.object(forKey: cacheKey(url))
    }

    /// 已完成的解码次数，用于确认视口外的图片没有被读取。
    static var decodeCount: Int { decodes.withLock { $0 } }
    private static let decodes = OSAllocatedUnfairLock(initialState: 0)

    static func thumbnail(at url: URL, maxPixel: Int = maxThumbnailPixel) -> CGImage? {
        let key = cacheKey(url)
        if let cached = ThumbnailCache.shared.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        ThumbnailCache.shared.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        decodes.withLock { $0 += 1 }
        return image
    }

    private static func cacheKey(_ url: URL) -> NSString { url.path as NSString }

    private static func positive(_ value: Any?) -> Double? {
        (value as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// 解码后的缩略图缓存；系统内存紧张时 NSCache 自动清空，视图下次出现时重新降采样。
final class ThumbnailCache: NSCache<NSString, CGImage>, @unchecked Sendable {
    static let shared: ThumbnailCache = {
        let cache = ThumbnailCache()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
}

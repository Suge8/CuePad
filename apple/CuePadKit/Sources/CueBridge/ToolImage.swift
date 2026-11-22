#if os(macOS)
import CueStore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 工具结果里的图（Agent 截的屏、读进来的图）进会话页的那一份：Mac 读会话时缩小再存进附件，原图只在 Mac 的会话文件里。
/// 量不另设每轮、每会话的上限，靠两样控住：同样的内容只存一份（附件按内容哈希，同一张图反复读是同一个键），对话过期时随之清掉
/// （`CueStore.pruneMessages`）。缩小为的是同步：Mac 上传每一份，手机在 Wi-Fi 上自动取小的；Pi 读图时只缩到 2000 像素、4.5MB 以内，
/// 截屏多的一天原图能有上百 MB，缩到长边 `maxPixels` 后一张约 `keptBytes`，同步量少一个数量级，手机全屏看界面截图仍清楚。
enum ToolImage {
    static let maxPixels = 1600
    static let keptBytes = 150_000
    /// 缩小后的编码：HEIC 留得住透明，同样清楚时约是 JPEG 的一半
    static let quality = 0.7

    static func data(at uri: String) -> Data? {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ","), uri[..<comma].hasSuffix(";base64") else { return nil }
            return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
        }
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ data: Data, in files: AttachmentFiles) throws -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if data.count <= keptBytes, max(width, height) <= maxPixels { return try files.store(data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return try files.store(try encoded(image))
    }

    private static func encoded(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}
#endif

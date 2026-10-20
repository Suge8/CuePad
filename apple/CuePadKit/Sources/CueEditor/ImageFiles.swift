import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片字节的格式处理：按目标需要转 PNG、JPEG 或给出 MIME 类型。转出来的方向标记烤进像素（不是每个看图的都认这个标记），
/// 原图的元数据（含拍摄地点）不带出去。
public nonisolated enum ImageFiles {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

    public static func mimeType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source)
        else { return nil }
        return UTType(identifier as String)?.preferredMIMEType
    }

    /// 已是 PNG 则原样返回，否则重新编码。
    public static func png(from data: Data) -> Data? {
        data.starts(with: pngSignature) ? data : encode(data, as: .png)
    }

    public static func jpeg(from data: Data, quality: Double) -> Data? {
        encode(data, as: .jpeg, [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ data: Data, as type: UTType, _ properties: [CFString: Any] = [:]) -> Data? {
        // 不限尺寸的"缩略图"就是整张原图，只是按方向标记转正了
        let upright = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, upright)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

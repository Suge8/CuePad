import CueStore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片字节的格式处理：读取原图文件，按目标需要转 PNG 或给出 MIME 类型。
nonisolated enum ImageFiles {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

    static func original(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func mimeType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source)
        else { return nil }
        return UTType(identifier as String)?.preferredMIMEType
    }

    /// 已是 PNG 则原样返回，否则重新编码。
    static func png(from data: Data) -> Data? {
        if data.starts(with: pngSignature) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

extension AttachmentFiles {
    /// 本机上的原图字节；文件不在本机时抛 `SendError.imageUnavailable`。
    func original(_ hash: String) throws -> Data {
        guard let url = fileURL(for: hash), let data = try? ImageFiles.original(at: url) else { throw SendError.imageUnavailable(hash) }
        return data
    }

    func png(_ hash: String) throws -> Data {
        guard let png = ImageFiles.png(from: try original(hash)) else { throw SendError.imageUnavailable(hash) }
        return png
    }
}

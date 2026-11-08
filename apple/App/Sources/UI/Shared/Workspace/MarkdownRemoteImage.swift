import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 阅读和分享走同一个有界下载；原始字节留给原图分享，阅读及长图只解码到所需分辨率。
nonisolated enum MarkdownRemoteImage {
    struct Asset: Sendable { let file: URL; let image: CGImage }
    private static let timeout: TimeInterval = 30
    private static let pixelSize = 2048

    enum Failure: LocalizedError {
        case unavailable, unreachable, invalidImage
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "图片链接暂时无法访问，请稍后重试")
            case .unreachable: String(localized: "图片链接无法访问，请检查链接")
            case .invalidImage: String(localized: "链接没有返回可读取的图片，请检查链接后重试")
            }
        }
    }

    @concurrent static func load(_ url: URL, into files: InspirationFiles) async throws -> Asset {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (download, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidImage }
        guard (200..<300).contains(response.statusCode) else {
            let temporary = response.statusCode == 408 || response.statusCode == 429 || (500..<600).contains(response.statusCode)
            throw temporary ? Failure.unavailable : Failure.unreachable
        }
        guard let source = CGImageSourceCreateWithURL(download as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize
              ] as CFDictionary) else { throw Failure.invalidImage }
        let file = files.directory.appending(path: "Download-\(UUID().uuidString).\(UTType(type as String)?.preferredFilenameExtension ?? "img")")
        try FileManager.default.moveItem(at: download, to: file)
        return Asset(file: file, image: image)
    }
}

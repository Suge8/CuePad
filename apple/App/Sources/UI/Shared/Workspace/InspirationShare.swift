import CueStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 分享只消费调用那一刻的不可变正文。原图交付真实文件；长图重新排完整篇，宽表按内容扩宽，绝不截取屏幕。
/// 单张最多 32 百万像素、最长边 16000 像素：超过时在分配位图之前明确失败，避免拖住主线程或被系统杀掉。
enum InspirationShare {
    private static let filenameByteLimit = 180
    private static let scale: CGFloat = 2
    private static let longestSide: CGFloat = 16_000
    private static let pixelBudget: CGFloat = 32_000_000

    static func prepare(_ source: String, originals: Bool, files: AttachmentFiles, colorScheme: ColorScheme) async throws -> InspirationPayload {
        let title = filenameTitle(source)
        let artifacts = try InspirationFiles()
        let keys = MarkdownMedia.imageKeys(in: source)
        var pictures: [String: CGImage] = [:]
        var originalsFiles: [URL] = []
        var downloads: [URL] = []
        defer { for file in downloads { try? FileManager.default.removeItem(at: file) } }
        for key in keys {
            try Task.checkCancellation()
            if let url = URL(string: key), url.scheme != nil {
                let asset = try await MarkdownRemoteImage.load(url, into: artifacts)
                downloads.append(asset.file)
                if originals { originalsFiles.append(asset.file) }
                else { pictures[key] = asset.image }
                continue
            }
            guard let file = files.fileURL(for: key) else { throw Failure.missing }
            if originals { originalsFiles.append(file) }
            else {
                guard let image = await Thumbnail.picture(key, height: Spacing.reading, scale: scale, in: files) else { throw Failure.image }
                pictures[key] = image
            }
        }
        if originals {
            guard !originalsFiles.isEmpty else { throw Failure.noImages }
            return InspirationPayload(files: artifacts, urls: try await copyOriginals(originalsFiles, title: title, into: artifacts))
        }
        await NextFrame.wait()
        try Task.checkCancellation()
        let palette = Palette(dark: colorScheme == .dark)
        let page = InspirationPaper(source: source, images: pictures)
            .padding(Spacing.section)
            .frame(width: width(of: source, images: pictures))
            .background(palette.paper)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: page)
        renderer.scale = scale
        var size = CGSize.zero
        renderer.render { measured, _ in size = measured }
        guard size.width * scale <= longestSide, size.height * scale <= longestSide,
              size.width * size.height * scale * scale <= pixelBudget else { throw Failure.tooLong }
        try Task.checkCancellation()
        guard let image = renderer.cgImage else { throw Failure.image }
        return InspirationPayload(files: artifacts, urls: [try await write(image, title: title, into: artifacts)])
    }

    /// 留出扩展名与原图序号的字节预算，跨平台路径分隔符与控制字符不进入文件名。
    private static func filenameTitle(_ source: String) -> String {
        let title = CardText.label(of: source).unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:*?\"<>|".unicodeScalars.contains(scalar) ? " " : String(scalar)
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var name = "", bytes = 0
        for character in title {
            let size = String(character).utf8.count
            guard bytes + size <= filenameByteLimit else { break }
            name.append(character)
            bytes += size
        }
        return name.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "."))).nonEmpty ?? String(localized: "灵感")
    }

    private static func width(of source: String, images: [String: CGImage]) -> CGFloat {
        var width = InspirationPaper.textWidth
        for block in MarkdownBlock.parse(source) {
            guard case .table(let table) = block.content else { continue }
            ImageRenderer(content: MarkdownBlockFrame(block: block) { MarkdownTableView(table: table, images: images, exporting: true) }).render { size, _ in width = max(width, size.width) }
        }
        return width + Spacing.section * 2
    }

    @concurrent private static func write(_ image: CGImage, title: String, into files: InspirationFiles) async throws -> URL {
        try Task.checkCancellation()
        let url = files.directory.appending(path: title + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.image }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.image }
        return url
    }

    /// 缓存可能被回收；分享持有自己的文件副本，字节不变，系统分享面板里也不会暴露内容哈希。
    @concurrent private static func copyOriginals(_ files: [URL], title: String, into artifacts: InspirationFiles) async throws -> [URL] {
        let directory = artifacts.directory
        return try files.enumerated().map { index, file in
            try Task.checkCancellation()
            let suffix = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
            let destination = directory.appending(path: "\(title) — \(index + 1)" + suffix)
            try FileManager.default.copyItem(at: file, to: destination)
            return destination
        }
    }

    nonisolated enum Failure: LocalizedError {
        case noImages, missing, image, tooLong
        var errorDescription: String? {
            switch self {
            case .noImages: String(localized: "这条灵感没有可分享的图片")
            case .missing: String(localized: "图片还没到这台设备，请在正文中点按图片下载，再重试")
            case .image: String(localized: "没能生成图片，请检查灵感内容后再分享")
            case .tooLong: String(localized: "内容太长，无法排成一张清晰的图片，请分成几条灵感后重试")
            }
        }
    }
}

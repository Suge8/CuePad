import CueStore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// 网页的缩略图：同全屏预览的拦截规则（`PreviewWebGuard`，脚本照跑、不联网）离线载入，渲首屏一张快照，
/// 按内容哈希存进 `LookFiles`。一次只渲一张：每张要起一个网页进程，一屏几张同时渲会把内存与 CPU 一起顶上去。
enum PageSnapshots {
    /// 渲染时的视口（CSS 像素）与快照宽（像素）：4:3 的一屏，够会话页的主图在 Mac 上铺满。
    /// Mac 全屏页按视口一比一摆快照（`PreviewPlace.frame`），与真网页的字一样大。
    static let viewport = CGSize(width: 1024, height: 768)
    private static let snapshotWidth: CGFloat = 1200

    private static var tail: Task<URL?, Never>?

    /// 快照存在 `LookFiles` 里（同缩略图一套），按内容哈希认。
    static func png(for preview: PiPreview, file: URL, caches: URL) async -> URL? {
        let target = LookFiles.url("\(preview.hash).page", in: caches)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let previous = tail
        let task = Task<URL?, Never> {
            _ = await previous?.value
            // 排在前面的可能刚渲过同一份
            if FileManager.default.fileExists(atPath: target.path) { return target }
            return await render(file, into: target)
        }
        tail = task
        return await task.value
    }

    private static func render(_ file: URL, into target: URL) async -> URL? {
        do {
            let page = try await PreviewWebGuard.page(for: file)
            // 载入完再等两帧（没有视图时帧可能不来，最多等 300ms）：脚本画的图表、字体落定后才是首屏的样子
            _ = try await page.callJavaScript("""
                await new Promise(done => { requestAnimationFrame(() => requestAnimationFrame(done)); setTimeout(done, 300) })
                """)
            let data = try await page.exported(as: .image(region: .rect(CGRect(origin: .zero, size: viewport)), snapshotWidth: snapshotWidth))
            try await LookFiles.write(data, to: target)
            return target
        } catch {
            return nil
        }
    }
}

/// 交付物画面的磁盘缓存（缩略图与网页快照只此一套）：库的缓存目录（`LibraryLocation.caches`）下的 `CuePadLooks/`，一张一个 PNG，
/// 按键名认（缩略图"哈希@框"、快照"哈希.page"）；系统可随时清，清了下次再出。内容按哈希定，存下就不会过时。
enum LookFiles {
    nonisolated static func url(_ key: String, in caches: URL) -> URL {
        caches.appending(path: "CuePadLooks", directoryHint: .isDirectory).appending(path: "\(key).png")
    }

    /// 存下的那张（已是要的大小，原样解出来）；没有为 nil。不经 `Thumbnails`：内存里那份由 `DeliverableLooks` 一处留着。
    /// 先读成数据再解：没存过是常态，`CGImageSourceCreateWithURL` 对不存在的文件每次都往系统日志记一条 ImageIO 错误。
    @concurrent static func image(_ key: String, in caches: URL) async -> CGImage? {
        guard let data = try? Data(contentsOf: url(key, in: caches), options: .mappedIfSafe),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// 存一张出好的画面；写不成就算了，下次再出。
    @concurrent static func store(_ image: CGImage, as key: String, in caches: URL) async {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? await write(data as Data, to: url(key, in: caches))
    }

    @concurrent static func write(_ data: Data, to target: URL) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

import AVFoundation
import CueEditor
import CueStore
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 一份交付物的缩略图里画什么：画面、宽高比（宽 / 高）与类型后面那一截（视频、音频的时长，PDF 的页数）。
nonisolated struct DeliverableLook: Sendable {
    var image: CGImage?
    /// 读不出画面的（音频、系统也给不出缩略图的）为 nil，按默认比例排
    var aspect: CGFloat?
    var detail: String?
}

/// 交付物缩略图（`DeliverableStrip`）全是真内容：图片按像素降采样；网页是离线 WebKit 渲的一张快照（`PageSnapshots`）；
/// Markdown 用全屏页同一个 `MarkdownText` 画首屏（不另写一套 Markdown 渲染）；
/// 音频只有时长；其余（视频、PDF、演示文稿、文稿、表格、3D、文本）交给系统缩略图。解码与生成都不在主线程。
/// 出好的画面按"哈希 + 像素"存一份到磁盘（`LookFiles`），也留在内存里（系统内存紧张时自动清）：每次启动后第一次打开 Cue 页不再把几十张原图重新解一遍
/// （真实库上一次约 650ms 的后台 CPU，与主线程抢核），同一份在别处再出现、滚走再滚回来都不重读，第一帧就是它该有的比例。
enum DeliverableLooks {
    private final class Entry {
        let look: DeliverableLook
        init(_ look: DeliverableLook) { self.look = look }
    }

    private static let memory = NSCache<NSString, Entry>()

    static func cached(_ preview: PiPreview, pixels: Int) -> DeliverableLook? {
        memory.object(forKey: key(preview, pixels) as NSString)?.look
    }

    /// `file` 是按原文件名放的那份（系统认类型靠扩展名）；`pixels` 是画面最长边的像素；`caches` 是库的缓存目录（`AttachmentFiles.caches`）。
    static func load(_ preview: PiPreview, file: URL, pixels: Int, scale: CGFloat, caches: URL) async -> DeliverableLook {
        if let cached = cached(preview, pixels: pixels) { return cached }
        let key = key(preview, pixels)
        async let detail = detail(preview, file: file)
        var look = DeliverableLook()
        if let stored = await LookFiles.image(key, in: caches, pixels: pixels) {
            look.image = stored
        } else if let made = await image(preview, file: file, pixels: pixels, scale: scale, caches: caches) {
            look.image = made
            await LookFiles.store(made, as: key, in: caches)
        }
        look.detail = await detail
        look.aspect = look.image.flatMap { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : nil }
        memory.setObject(Entry(look), forKey: key as NSString)
        return look
    }

    /// 从原文件出一张画面；音频与出不来的为 nil。
    private static func image(_ preview: PiPreview, file: URL, pixels: Int, scale: CGFloat, caches: URL) async -> CGImage? {
        switch preview.kind {
        case .image: await decode(file, pixels: pixels)
        case .web: if let snapshot = await PageSnapshots.png(for: preview, file: file, caches: caches) { await decode(snapshot, pixels: pixels) } else { nil }
        case .markdown: await markdown(file, pixels: pixels)
        case .audio: nil
        default: await systemThumbnail(file, pixels: pixels, scale: scale)
        }
    }

    /// 类型后面那一截：视频、音频的时长，PDF 的页数。
    private static func detail(_ preview: PiPreview, file: URL) async -> String? {
        switch preview.kind {
        case .audio, .video: await duration(file)
        case .pdf: await pageCount(file).map { "\($0) 页" }
        default: nil
        }
    }

    private static func key(_ preview: PiPreview, _ pixels: Int) -> String { "\(preview.hash)@\(pixels)" }

    /// Markdown 的首屏：纸色底上的 `MarkdownText`，4:3（同网页快照）。只读开头一段，首屏之外的字不进排版；
    /// 按浅色画，深色下由缩略图统一压暗（同网页快照）。
    private static func markdown(_ file: URL, pixels: Int) async -> CGImage? {
        guard let source = await head(of: file) else { return nil }
        let palette = Palette(dark: false)
        let page = MarkdownText(source: source)
            .padding(20)
            .frame(width: markdownPage.width, height: markdownPage.height, alignment: .topLeading)
            .background(palette.paper)
            .environment(\.palette, palette)
        let renderer = ImageRenderer(content: page)
        renderer.scale = CGFloat(pixels) / markdownPage.width
        return renderer.cgImage
    }

    /// 画成多大的一页再缩进卡片：比阅读栏窄，缩进主图、横排时字仍认得出（480 宽时列表只剩七八磅）
    private static let markdownPage = CGSize(width: 360, height: 270)

    @concurrent private static func head(of file: URL) async -> String? {
        (try? String(contentsOf: file, encoding: .utf8)).map { String($0.prefix(3000)) }
    }

    @concurrent private static func decode(_ file: URL, pixels: Int) async -> CGImage? {
        Thumbnails.image(at: file, maxPixel: pixels)
    }

    @concurrent private static func pageCount(_ file: URL) async -> Int? {
        CGPDFDocument(file as CFURL).map(\.numberOfPages)
    }

    private static func systemThumbnail(_ file: URL, pixels: Int, scale: CGFloat) async -> CGImage? {
        let side = CGFloat(pixels) / scale
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    private static func duration(_ file: URL) async -> String? {
        (try? await AVURLAsset(url: file).load(.duration)).flatMap { clock($0.seconds) }
    }

    /// 时长写成"0:03""12:40""1:02:05"。
    static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: pattern))
    }
}

/// 网页的缩略图：同全屏预览的拦截规则（`PreviewWebGuard`，脚本照跑、不联网）离线载入，渲首屏一张快照，
/// 按内容哈希存进 `LookFiles`。一次只渲一张：每张要起一个网页进程，一屏几张同时渲会把内存与 CPU 一起顶上去。
enum PageSnapshots {
    /// 渲染时的视口（CSS 像素）与快照宽（像素）：4:3 的一屏，够结果卡的主图在 Mac 上铺满。
    private static let viewport = CGSize(width: 1024, height: 768)
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
/// 按键名认（缩略图"哈希@像素"、快照"哈希.page"）；系统可随时清，清了下次再出。内容按哈希定，存下就不会过时。
enum LookFiles {
    nonisolated static func url(_ key: String, in caches: URL) -> URL {
        caches.appending(path: "CuePadLooks", directoryHint: .isDirectory).appending(path: "\(key).png")
    }

    /// 存下的那张（已是要的大小，读出来不再缩）；没有为 nil。
    @concurrent static func image(_ key: String, in caches: URL, pixels: Int) async -> CGImage? {
        let file = url(key, in: caches)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return Thumbnails.image(at: file, maxPixel: pixels)
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

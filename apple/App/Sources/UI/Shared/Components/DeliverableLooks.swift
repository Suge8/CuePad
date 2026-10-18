import AVFoundation
import CueEditor
import CueStore
import QuickLookThumbnailing
import SwiftUI
import WebKit

/// 一份交付物的缩略图里画什么：画面、宽高比（宽 / 高）与类型后面那一截（视频、音频的时长，PDF 的页数）。
nonisolated struct DeliverableLook: Sendable {
    var image: CGImage?
    /// 读不出画面的（音频、系统也给不出缩略图的）为 nil，按默认比例排
    var aspect: CGFloat?
    var detail: String?
}

/// 画面画在多大的框里（像素）：`fills` 是铺满框、多出来的裁掉（按短的那一边够），否则是整张放进框里（按长的那一边够）；
/// `width` 为 0 是不限宽（横向滑的一排：同高、宽随比例）。解码与生成按框定尺寸，不按猜的最长边：同高 150 点的一排里一张 16:9 截图
/// 只要 800×450 像素，按"最长边是高的 4 倍"解成 1800 像素宽是它的五倍多。
nonisolated struct LookBox: Hashable, Sendable {
    var width: Int
    var height: Int
    var fills: Bool

    /// 横图、全景图最多按框的 4 倍解：再宽的那一截反正被裁掉或缩得看不清。
    private static let longestFactor = 4

    /// 原图 `size` 要解到的最长边（像素，不放大由解码自己管）。
    func longestSide(of size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return max(width, height) }
        let byHeight = CGFloat(height) / size.height
        let byWidth = width > 0 ? CGFloat(width) / size.width : byHeight
        let scale = fills ? max(byWidth, byHeight) : min(byWidth, byHeight)
        return min(Int((scale * max(size.width, size.height)).rounded(.up)), Self.longestFactor * max(width, height))
    }

    /// 交给系统缩略图的框（它总是整张放进框里）：不限宽时按高的 4 倍。
    var fitting: CGSize { CGSize(width: width > 0 ? width : Self.longestFactor * height, height: height) }
}

/// 交付物缩略图（`DeliverableStrip`）全是真内容：图片按框降采样（`LookBox`）；网页是离线 WebKit 渲的一张快照（`PageSnapshots`）；
/// Markdown 用全屏页同一个 `MarkdownText` 画首屏（不另写一套 Markdown 渲染）；
/// 音频只有时长；其余（视频、PDF、演示文稿、文稿、表格、3D、文本）交给系统缩略图。解码与生成都不在主线程。
/// 读到的按"哈希 + 像素"留在内存里（系统内存紧张时自动清），同一份在别处再出现、滚走再滚回来都不重读，第一帧就是它该有的比例。
enum DeliverableLooks {
    private final class Entry {
        let look: DeliverableLook
        init(_ look: DeliverableLook) { self.look = look }
    }

    private static let memory = NSCache<NSString, Entry>()

    static func cached(_ preview: PiPreview, box: LookBox) -> DeliverableLook? {
        memory.object(forKey: key(preview, box))?.look
    }

    /// `file` 是按原文件名放的那份（系统认类型靠扩展名）；`box` 是画面画在多大的框里。
    static func load(_ preview: PiPreview, file: URL, box: LookBox, scale: CGFloat) async -> DeliverableLook {
        if let cached = cached(preview, box: box) { return cached }
        var look = DeliverableLook()
        switch preview.kind {
        case .image:
            look.image = await decode(file, box: box)
        case .web:
            if let snapshot = await PageSnapshots.png(for: preview, file: file) { look.image = await decode(snapshot, box: box) }
        case .markdown:
            look.image = await markdown(file, box: box)
        case .audio:
            look.detail = await duration(file)
        case .video:
            async let time = duration(file)
            look.image = await systemThumbnail(file, box: box, scale: scale)
            look.detail = await time
        case .pdf:
            look.image = await systemThumbnail(file, box: box, scale: scale)
            look.detail = await pageCount(file).map { "\($0) 页" }
        default:
            look.image = await systemThumbnail(file, box: box, scale: scale)
        }
        look.aspect = look.image.flatMap { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : nil }
        memory.setObject(Entry(look), forKey: key(preview, box))
        return look
    }

    private static func key(_ preview: PiPreview, _ box: LookBox) -> NSString {
        "\(preview.hash)@\(box.width)x\(box.height)\(box.fills ? "fill" : "fit")" as NSString
    }

    /// Markdown 的首屏：纸色底上的 `MarkdownText`，4:3（同网页快照）。只读开头一段，首屏之外的字不进排版；
    /// 按浅色画，深色下由缩略图统一压暗（同网页快照）。
    private static func markdown(_ file: URL, box: LookBox) async -> CGImage? {
        guard let source = await head(of: file) else { return nil }
        let palette = Palette(dark: false)
        let page = MarkdownText(source: source)
            .padding(20)
            .frame(width: markdownPage.width, height: markdownPage.height, alignment: .topLeading)
            .background(palette.paper)
            .environment(\.palette, palette)
        let renderer = ImageRenderer(content: page)
        renderer.scale = CGFloat(box.longestSide(of: markdownPage)) / markdownPage.width
        return renderer.cgImage
    }

    /// 画成多大的一页再缩进卡片：比阅读栏窄，缩进主图、横排时字仍认得出（480 宽时列表只剩七八磅）
    private static let markdownPage = CGSize(width: 360, height: 270)

    @concurrent private static func head(of file: URL) async -> String? {
        (try? String(contentsOf: file, encoding: .utf8)).map { String($0.prefix(3000)) }
    }

    @concurrent private static func decode(_ file: URL, box: LookBox) async -> CGImage? {
        guard let size = Thumbnails.pixelSize(at: file) else { return nil }
        return Thumbnails.image(at: file, maxPixel: box.longestSide(of: size))
    }

    @concurrent private static func pageCount(_ file: URL) async -> Int? {
        CGPDFDocument(file as CFURL).map(\.numberOfPages)
    }

    private static func systemThumbnail(_ file: URL, box: LookBox, scale: CGFloat) async -> CGImage? {
        let size = box.fitting
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: size.width / scale, height: size.height / scale), scale: scale, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else { return nil }
        return await shrunk(image, to: box)
    }

    /// 系统缩略图不一定照要的尺寸给（视频常按原片给，真实库里一张约 11MB，画上屏时再拷一份）：超过框的重画到框的尺寸，原图随即放掉。
    /// 不加这一步时真实库的 iPhone Cue 页常驻 243MB，其中系统缩略图与它在屏上的拷贝约 140MB。
    @concurrent private static func shrunk(_ image: CGImage, to box: LookBox) async -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let longest = box.longestSide(of: size)
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
/// 按内容哈希存在缓存目录（系统可随时清，清了下次再渲）。一次只渲一张：每张要起一个网页进程，一屏几张同时渲会把内存与 CPU 一起顶上去。
enum PageSnapshots {
    /// 渲染时的视口（CSS 像素）与快照宽（像素）：4:3 的一屏，够结果卡的主图在 Mac 上铺满。
    private static let viewport = CGSize(width: 1024, height: 768)
    private static let snapshotWidth: CGFloat = 1200

    private static var tail: Task<URL?, Never>?

    static func png(for preview: PiPreview, file: URL) async -> URL? {
        let target = directory.appending(path: "\(preview.hash).png")
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

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "CuePadSnapshots", directoryHint: .isDirectory)
    }

    private static func render(_ file: URL, into target: URL) async -> URL? {
        do {
            let page = try await PreviewWebGuard.page(for: file)
            // 载入完再等两帧（没有视图时帧可能不来，最多等 300ms）：脚本画的图表、字体落定后才是首屏的样子
            _ = try await page.callJavaScript("""
                await new Promise(done => { requestAnimationFrame(() => requestAnimationFrame(done)); setTimeout(done, 300) })
                """)
            let data = try await page.exported(as: .image(region: .rect(CGRect(origin: .zero, size: viewport)), snapshotWidth: snapshotWidth))
            try await write(data, to: target)
            return target
        } catch {
            return nil
        }
    }

    @concurrent private static func write(_ data: Data, to target: URL) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

import AVFoundation
import CueEditor
import CueStore
import QuickLookThumbnailing
import WebKit

/// 一份交付物的缩略图里画什么：画面、宽高比（宽 / 高）与类型后面那一截（视频、音频的时长，PDF 的页数）。
nonisolated struct DeliverableLook: Sendable {
    var image: CGImage?
    /// 读不出画面的（音频、系统也给不出缩略图的）为 nil，按默认比例排
    var aspect: CGFloat?
    var detail: String?
}

/// 交付物缩略图（`DeliverableStrip`）全是真内容：图片按像素降采样；网页与 Markdown 是离线 WebKit 渲的一张快照（`PageSnapshots`）；
/// 音频只有时长；其余（视频、PDF、演示文稿、文稿、表格、3D、文本）交给系统缩略图。解码与生成都不在主线程。
/// 读到的按"哈希 + 像素"留在内存里（系统内存紧张时自动清），同一份在别处再出现、滚走再滚回来都不重读，第一帧就是它该有的比例。
enum DeliverableLooks {
    private final class Entry {
        let look: DeliverableLook
        init(_ look: DeliverableLook) { self.look = look }
    }

    private static let memory = NSCache<NSString, Entry>()

    static func cached(_ preview: PiPreview, pixels: Int) -> DeliverableLook? {
        memory.object(forKey: key(preview, pixels))?.look
    }

    /// `file` 是按原文件名放的那份（系统认类型靠扩展名）；`pixels` 是画面最长边的像素。
    static func load(_ preview: PiPreview, file: URL, pixels: Int, scale: CGFloat) async -> DeliverableLook {
        if let cached = cached(preview, pixels: pixels) { return cached }
        var look = DeliverableLook()
        switch preview.kind {
        case .image:
            look.image = await decode(file, pixels: pixels)
        case .web, .markdown:
            if let snapshot = await PageSnapshots.png(for: preview, file: file) { look.image = await decode(snapshot, pixels: pixels) }
        case .audio:
            look.detail = await duration(file)
        case .video:
            async let time = duration(file)
            look.image = await systemThumbnail(file, pixels: pixels, scale: scale)
            look.detail = await time
        case .pdf:
            look.image = await systemThumbnail(file, pixels: pixels, scale: scale)
            look.detail = await pageCount(file).map { "\($0) 页" }
        default:
            look.image = await systemThumbnail(file, pixels: pixels, scale: scale)
        }
        look.aspect = look.image.flatMap { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : nil }
        memory.setObject(Entry(look), forKey: key(preview, pixels))
        return look
    }

    private static func key(_ preview: PiPreview, _ pixels: Int) -> NSString { "\(preview.hash)@\(pixels)" as NSString }

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

/// 网页与 Markdown 的缩略图：同全屏预览的拦截规则（`PreviewWebGuard`，脚本照跑、不联网）离线载入，渲首屏一张快照，
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
            return await render(preview.kind, file: file, into: target)
        }
        tail = task
        return await task.value
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "CuePadSnapshots", directoryHint: .isDirectory)
    }

    private static func render(_ kind: PiPreviewKind?, file: URL, into target: URL) async -> URL? {
        do {
            let page: WebPage
            if kind == .markdown {
                page = try await PreviewWebGuard.page(
                    loading: Data(MarkdownHTML.page(try await read(file)).utf8), mimeType: "text/html", untilLoaded: true)
            } else {
                page = try await PreviewWebGuard.page(for: file, untilLoaded: true)
            }
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

    @concurrent private static func read(_ file: URL) async throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @concurrent private static func write(_ data: Data, to target: URL) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

/// Markdown 拼成一页给 WebKit 渲缩略图：块照 `MarkdownBlock` 认，行内的记号只留文字（缩略图里看的是版面）。
nonisolated enum MarkdownHTML {
    static func page(_ source: String) -> String {
        let body = MarkdownBlock.parse(source).map { block in
            switch block {
            case .paragraph(let text): "<p>\(inline(text))</p>"
            case .heading(let level, let text): "<h\(min(level, 4))>\(inline(text))</h\(min(level, 4))>"
            case .item(let marker, let text, let depth): "<p class=li style=\"margin-left:\(depth * 20 + 4)px\">\(escape(marker)) \(inline(text))</p>"
            case .quote(let text): "<blockquote>\(inline(text))</blockquote>"
            case .code(let text): "<pre>\(escape(text))</pre>"
            case .rule: "<hr>"
            case .table(let table):
                "<table><tr>" + table.header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                    + table.rows.map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>"
            }
        }.joined(separator: "\n")
        return """
            <!doctype html><html><head><meta charset="utf-8"><style>
            body{margin:0;padding:48px 64px;background:#FCFBF8;color:#1C1B19;font:22px/1.6 -apple-system,"PingFang SC",sans-serif}
            h1{font-size:40px;margin:0 0 20px}h2{font-size:32px;margin:28px 0 14px}h3,h4{font-size:26px;margin:24px 0 10px}
            p{margin:0 0 14px}.li{margin-bottom:6px}blockquote{margin:0 0 14px;padding-left:16px;border-left:4px solid #ddd;color:#666}
            pre{background:#F1EFEA;padding:16px;border-radius:10px;font:18px ui-monospace,monospace;white-space:pre-wrap}
            table{border-collapse:collapse;margin-bottom:14px}th,td{border-bottom:1px solid #e4e1da;padding:6px 14px;text-align:left}th{background:#F1EFEA}
            hr{border:0;border-top:1px solid #e4e1da;margin:20px 0}
            </style></head><body>\(body)</body></html>
            """
    }

    private static func inline(_ text: String) -> String {
        let plain = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text
        return escape(plain).replacing("\n", with: "<br>")
    }

    private static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}

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

/// 画面画在多大的框里（像素）：`fills` 是铺满框、多出来的裁掉（按短的那一边够），否则是整张放进框里（按长的那一边够）；
/// `width` 为 0 是不限宽（横向滑的一排：同高、宽随比例）。解码与生成按框定尺寸，不按猜的最长边：同高 150 点的一排里一张 16:9 截图
/// 只要 800×450 像素，按"最长边是高的 4 倍"解成 1800 像素宽是它的五倍多。
nonisolated struct LookBox: Hashable, Sendable {
    var width: Int
    var height: Int
    var fills: Bool
    /// 出画面时就裁成框的比例、取细节最多的那一段（`DeliverableLooks.detailCrop`）：提问的方形缩略图只为认出是哪张，
    /// 截图的中间常是空白，居中裁认不出。裁好的随缩略图存，画的时候居中铺满即可。
    var framed = false

    /// 限宽的框里，横图、全景图最多按框的 4 倍解：再宽的那一截反正被裁掉或缩得看不清。不限宽的一排里格子按真实比例给宽，不封顶，否则全景图会被放大。
    private static let longestFactor = 4

    /// 原图 `size` 要解到的最长边（像素，不放大由解码自己管）。
    func longestSide(of size: CGSize) -> Int {
        guard size.width > 0, size.height > 0 else { return max(width, height) }
        let longest = max(size.width, size.height)
        let byHeight = CGFloat(height) / size.height
        guard width > 0 else { return Int((byHeight * longest).rounded(.up)) }
        let byWidth = CGFloat(width) / size.width
        let scale = fills ? max(byWidth, byHeight) : min(byWidth, byHeight)
        return min(Int((scale * longest).rounded(.up)), Self.longestFactor * max(width, height))
    }

    /// 先交给系统缩略图的框（它总是整张放进框里）：不限宽时是边长为高 4 倍的方框（视频、文稿没有更宽的），出来的再缩回框——
    /// 系统按最长边缓存缩略图，要 4h×h 的扁框会把竖版的一张小图记在这个尺寸下，全屏页随后要同边长的方框时拿到的就是它，糊。
    /// 铺满的框里比例与框不同的（竖版 PDF、竖拍视频）这样出得太小，见 `DeliverableLooks.systemThumbnail`。
    var fitting: CGSize {
        width > 0 ? CGSize(width: width, height: height) : CGSize(width: Self.longestFactor * height, height: Self.longestFactor * height)
    }
}

/// 交付物缩略图（`DeliverableTile`）全是真内容：图片按框降采样（`LookBox`）；网页是离线 WebKit 渲的一张快照（`PageSnapshots`）；
/// Markdown 用全屏页同一个 `MarkdownText` 画首屏（不另写一套 Markdown 渲染）；
/// 音频只有时长；其余（视频、PDF、演示文稿、文稿、表格、3D、文本）交给系统缩略图。解码与系统缩略图不在主线程；网页快照（`WebPage`）与
/// Markdown 首屏（`ImageRenderer`）只能在主线程上起，新出一张排在这一帧画上屏之后（`NextFrame.drawn`）：排在这一帧提交之前的话，起网页进程那几十毫秒就压在
/// 页面出来的这一帧上（第一次打开 Cue 页，结果卡与拍板卡里点名的网页还没有快照）。
/// 出好的画面按"哈希 + 框"存一份到磁盘（`LookFiles`），也留在内存里（系统内存紧张时自动清）：每次启动后第一次打开 Cue 页不再把几十张原图重新解一遍
/// （真实库上一次约 650ms 的后台 CPU，与主线程抢核），同一份在别处再出现、滚走再滚回来都不重读，第一帧就是它该有的比例。
enum DeliverableLooks {
    private final class Entry {
        let look: DeliverableLook
        init(_ look: DeliverableLook) { self.look = look }
    }

    private static let memory = NSCache<NSString, Entry>()

    static func cached(_ preview: PiPreview, box: LookBox) -> DeliverableLook? {
        memory.object(forKey: key(preview, box) as NSString)?.look
    }

    /// `file` 是按原文件名放的那份（系统认类型靠扩展名）；`box` 是画面画在多大的框里；`caches` 是库的缓存目录（`AttachmentFiles.caches`）。
    static func load(_ preview: PiPreview, file: URL, box: LookBox, scale: CGFloat, caches: URL) async -> DeliverableLook {
        if let cached = cached(preview, box: box) { return cached }
        let key = key(preview, box)
        async let detail = detail(preview, file: file)
        var look = DeliverableLook()
        if let stored = await LookFiles.image(key, in: caches) {
            look.image = stored
        } else {
            await NextFrame.drawn()
            if var made = await image(preview, file: file, box: box, scale: scale, caches: caches) {
                if box.framed { made = await made.cropping(to: detailRegion(made, aspect: CGFloat(box.width) / CGFloat(box.height))) ?? made }
                look.image = made
                await LookFiles.store(made, as: key, in: caches)
            }
        }
        look.detail = await detail
        look.aspect = look.image.flatMap { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : nil }
        memory.setObject(Entry(look), forKey: key as NSString)
        return look
    }

    /// 从原文件出一张画面；音频与出不来的为 nil。
    private static func image(_ preview: PiPreview, file: URL, box: LookBox, scale: CGFloat, caches: URL) async -> CGImage? {
        switch preview.kind {
        case .image: await decode(file, box: box)
        case .web: if let snapshot = await PageSnapshots.png(for: preview, file: file, caches: caches) { await decode(snapshot, box: box) } else { nil }
        case .markdown: await markdown(file, box: box)
        case .audio: nil
        default: await systemThumbnail(file, box: box, scale: scale)
        }
    }

    /// 类型后面那一截：视频、音频的时长，PDF 的页数。
    private static func detail(_ preview: PiPreview, file: URL) async -> String? {
        switch preview.kind {
        case .audio, .video: await duration(file)
        case .pdf: await pageCount(file).map { String(localized: "\($0) 页") }
        default: nil
        }
    }

    private static func key(_ preview: PiPreview, _ box: LookBox) -> String {
        "\(preview.hash)@\(box.width)x\(box.height)\(box.fills ? "fill" : "fit")\(box.framed ? "-framed" : "")"
    }

    /// 按宽高比 `aspect` 取一块（像素，原点左上，同 CGImage）：占满短的那一边，沿长的那一边挪到细节最多的地方（`detail`），细节一样多的几处取中间那处，
    /// 内容整段放得下时就居中在框里；整张没有细节时居中。截图与页面上有字、有控件的地方细节多，空白的底没有：
    /// 页面的标题与表单、几张方案图各自不同的那一块都落在框里。
    /// 不用 Vision 的注意力显著热图：白底页面上它热成一大片，按重心居中常落在两块内容之间的空白上；模拟器上请求出错，截图、录屏里全落到兜底。
    /// Mac 全屏页飞回点名图时照它算缩略图露出的是整张的哪一块（`PreviewCrop.detail`）。
    @concurrent static func detailRegion(_ image: CGImage, aspect: CGFloat) async -> CGRect {
        let width = image.width, height = image.height
        let tall = CGFloat(width) / CGFloat(height) < aspect
        let cropWidth = tall ? width : Int(CGFloat(height) * aspect)
        let cropHeight = tall ? Int(CGFloat(width) / aspect) : height
        let along = tall ? height : width, span = tall ? cropHeight : cropWidth
        let start = detail(image, rows: tall).map { profile in
            let first = window(in: profile, covering: CGFloat(span) / CGFloat(along))
            return Int(CGFloat(first) / CGFloat(profile.count) * CGFloat(along))
        } ?? (along - span) / 2
        let offset = min(max(start, 0), along - span)
        return tall ? CGRect(x: 0, y: offset, width: cropWidth, height: cropHeight) : CGRect(x: offset, y: 0, width: cropWidth, height: cropHeight)
    }

    /// 长度占 `covering`（0…1）的一框从哪一格起：框里的和最大；差不多大（差 `detailSlack` 以内）的几处取中间那处。
    nonisolated private static func window(in sums: [Double], covering: CGFloat) -> Int {
        let length = max(1, min(sums.count, Int((covering * CGFloat(sums.count)).rounded())))
        let totals = (0...(sums.count - length)).map { sums[$0..<$0 + length].reduce(0, +) }
        let best = totals.max() ?? 0
        let near = totals.indices.filter { totals[$0] >= best * (1 - detailSlack) }
        return near[near.count / 2]
    }

    nonisolated private static let detailSlack = 0.02
    /// 量细节时短的那一边缩到这么多像素：够分出一行字，量一次不到一毫秒。
    nonisolated private static let detailSide = 64

    /// 每一行（`rows`）或每一列的细节：缩小成灰度后相邻像素的明暗差之和（原点左上，同 CGImage）；画不出来为 nil。
    nonisolated private static func detail(_ image: CGImage, rows: Bool) -> [Double]? {
        let ratio = CGFloat(max(image.width, image.height)) / CGFloat(min(image.width, image.height))
        let long = Int((CGFloat(detailSide) * ratio).rounded())
        let width = rows ? detailSide : long, height = rows ? long : detailSide
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ).map { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) } != nil
        }
        guard drawn else { return nil }
        var sums = [Double](repeating: 0, count: rows ? height : width)
        for y in 0..<height - 1 {
            for x in 0..<width - 1 {
                let here = Int(pixels[y * width + x])
                let change = abs(here - Int(pixels[y * width + x + 1])) + abs(here - Int(pixels[(y + 1) * width + x]))
                sums[rows ? y : x] += Double(change)
            }
        }
        return sums
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
        Thumbnails.decoded(at: file, longestSide: box.longestSide(of:))
    }

    @concurrent private static func pageCount(_ file: URL) async -> Int? {
        CGPDFDocument(file as CFURL).map(\.numberOfPages)
    }

    /// 系统缩略图只会整张放进框里：先按框要一张，铺满框还不够大（比例与框不同，如竖版 PDF 放进横的主图）就按它的比例算出要多大再要一张，
    /// 不一上来就按最大可能要（Mac 主图那样要会渲出五千多像素见方的一页）。
    private static func systemThumbnail(_ file: URL, box: LookBox, scale: CGFloat) async -> CGImage? {
        guard let first = await systemThumbnail(file, fitting: box.fitting, scale: scale) else { return nil }
        let longest = box.longestSide(of: CGSize(width: first.width, height: first.height))
        let image = longest > max(first.width, first.height)
            ? await systemThumbnail(file, fitting: CGSize(width: longest, height: longest), scale: scale) ?? first : first
        return await shrunk(image, to: longest)
    }

    private static func systemThumbnail(_ file: URL, fitting size: CGSize, scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: size.width / scale, height: size.height / scale), scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// 系统缩略图不一定照要的尺寸给（视频常按原片给，真实库里一张约 11MB，画上屏时再拷一份）：超过框的重画到框的尺寸，原图随即放掉。
    /// 不加这一步时真实库的 iPhone Cue 页常驻 243MB，其中系统缩略图与它在屏上的拷贝约 140MB。
    @concurrent private static func shrunk(_ image: CGImage, to longest: Int) async -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
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
/// 按内容哈希存进 `LookFiles`。一次只渲一张：每张要起一个网页进程，一屏几张同时渲会把内存与 CPU 一起顶上去。
enum PageSnapshots {
    /// 渲染时的视口（CSS 像素）与快照宽（像素）：4:3 的一屏，够会话页的主图在 Mac 上铺满。
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
/// 按键名认（缩略图"哈希@框"、快照"哈希.page"）；系统可随时清，清了下次再出。内容按哈希定，存下就不会过时。
enum LookFiles {
    nonisolated static func url(_ key: String, in caches: URL) -> URL {
        caches.appending(path: "CuePadLooks", directoryHint: .isDirectory).appending(path: "\(key).png")
    }

    /// 存下的那张（已是要的大小，原样解出来）；没有为 nil。不经 `Thumbnails`：内存里那份由 `DeliverableLooks` 一处留着。
    @concurrent static func image(_ key: String, in caches: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(key, in: caches) as CFURL, nil) else { return nil }
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

import AVFoundation
import CueEditor
import CueStore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

nonisolated struct DeliverableLook: Sendable {
    var image: CGImage?
    var aspect: CGFloat?
    var detail: String?
}

/// 解码与生成按框定尺寸，不按猜的最长边：同高 150 点的一排里一张 16:9 截图只要 800×450 像素，按"最长边是高的 4 倍"解成 1800 像素宽是它的五倍多。
nonisolated struct LookBox: Hashable, Sendable {
    var width: Int
    var height: Int
    var fills: Bool
    /// 提问的方形缩略图只为认出是哪张，截图的中间常是空白，居中裁认不出；裁好的随缩略图存，画的时候居中铺满即可。
    var framed = false
    /// 截图与网页是别人的画面，只能压暗；自己排的页按此刻的外观画，Mac 全屏页落地时换成的正文同色，不在深色里亮出一张白纸。
    var dark = false

    /// 限宽的框里，横图、全景图最多按框的 4 倍解：再宽的那一截反正被裁掉或缩得看不清。不限宽的一排里格子按真实比例给宽，不封顶，否则全景图会被放大。
    private static let longestFactor = 4

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

/// 解码与系统缩略图不在主线程；网页快照（`WebPage`）与 Markdown 首屏（`ImageRenderer`）只能在主线程上起，新出一张排在这一帧画上屏之后（`NextFrame.drawn`）：排在这一帧提交之前的话，起网页进程那几十毫秒就压在页面出来的这一帧上（第一次打开 Cue 页，结果卡与拍板卡里点名的网页还没有快照）。
/// 出好的画面按"哈希 + 框"存一份到磁盘（`LookFiles`），也留在内存里（系统内存紧张时自动清）：每次启动后第一次打开 Cue 页不再把几十张原图重新解一遍（真实库上一次约 650ms 的后台 CPU，与主线程抢核），同一份在别处再出现、滚走再滚回来都不重读，第一帧就是它该有的比例。
enum DeliverableLooks {
    private final class Entry {
        let look: DeliverableLook
        init(_ look: DeliverableLook) { self.look = look }
    }

    private static let memory = NSCache<NSString, Entry>()

    static func cached(_ preview: PiPreview, box: LookBox) -> DeliverableLook? {
        memory.object(forKey: key(preview, box) as NSString)?.look
    }

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

    private static func image(_ preview: PiPreview, file: URL, box: LookBox, scale: CGFloat, caches: URL) async -> CGImage? {
        switch preview.kind {
        case .image: await decode(file, box: box)
        case .web: if let snapshot = await PageSnapshots.png(for: preview, file: file, caches: caches) { await decode(snapshot, box: box) } else { nil }
        case .markdown: await markdown(file, box: box)
        case .diff, .text: await code(file, diff: preview.kind == .diff, box: box)
        case .audio: nil
        default: await systemThumbnail(file, box: box, scale: scale)
        }
    }

    private static func detail(_ preview: PiPreview, file: URL) async -> String? {
        switch preview.kind {
        case .audio, .video: await duration(file)
        case .pdf: await pageCount(file).map { String(localized: "\($0) 页") }
        default: nil
        }
    }

    /// 自己排出来的那几类（`rendered`）的画法变过就换一个 `pageLook`，磁盘上旧画法的那张不再认。
    private static func key(_ preview: PiPreview, _ box: LookBox) -> String {
        let page = drawn(preview.kind) ? "-\(pageLook)\(box.dark ? "-dark" : "")" : ""
        return "\(preview.hash)@\(box.width)x\(box.height)\(box.fills ? "fill" : "fit")\(box.framed ? "-framed" : "")\(page)"
    }

    private static let pageLook = "faded"

    /// 按外观画（`LookBox.dark`），深色下不再压暗。
    static func drawn(_ kind: PiPreviewKind?) -> Bool { [.markdown, .diff, .text].contains(kind) }

    /// 沿长的那一边挪到细节最多的地方：截图与页面上有字、有控件的地方细节多，空白的底没有，页面的标题与表单、几张方案图各自不同的那一块都落在框里。
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

    nonisolated private static func window(in sums: [Double], covering: CGFloat) -> Int {
        let length = max(1, min(sums.count, Int((covering * CGFloat(sums.count)).rounded())))
        let totals = (0...(sums.count - length)).map { sums[$0..<$0 + length].reduce(0, +) }
        let best = totals.max() ?? 0
        let near = totals.indices.filter { totals[$0] >= best * (1 - detailSlack) }
        return near[near.count / 2]
    }

    nonisolated private static let detailSlack = 0.02
    /// 够分出一行字，量一次不到一毫秒。
    nonisolated private static let detailSide = 64

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

    /// 只读开头一段，首屏之外的字不进排版。
    /// 渲染成缩略图的那一页的页边：照纸上文档的页边比例留（缩到卡上看着像一页纸），与界面的间距档无关。
    private static let markdownMargin: CGFloat = 20

    private static func markdown(_ file: URL, box: LookBox) async -> CGImage? {
        guard let source = await head(of: file) else { return nil }
        let palette = Palette(dark: box.dark)
        return rendered(MarkdownText(source: source, style: .document).padding(Self.markdownMargin), palette: palette, box: box)
    }

    /// 系统给纯文本的缩略图是一页纸上的几粒小字，缩进卡片就是一张白纸。
    private static func code(_ file: URL, diff: Bool, box: LookBox) async -> CGImage? {
        guard let source = await head(of: file) else { return nil }
        let palette = Palette(dark: box.dark)
        guard diff else {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).prefix(codeLines).joined(separator: "\n")
            return rendered(Text(verbatim: lines).font(Typography.diff).foregroundStyle(palette.ink).padding(Self.markdownMargin), palette: palette, box: box)
        }
        let parsed = await parse(source)
        let layout = DiffLayout(parsed, viewport: markdownPage.width)
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(parsed.lines.prefix(codeLines)) { DiffRow(line: $0, layout: layout) }
        }
        return rendered(rows, palette: palette, box: box)
    }

    private static let codeLines = 18

    @concurrent private static func parse(_ source: String) async -> UnifiedDiff { UnifiedDiff(source) }

    /// 字号随平台不同，页底常正好切在一行字中间，横切半行读作排坏了；淡出说的是"下面还有"（同会话条多到要滚时的下沿）。
    private static func rendered(_ content: some View, palette: Palette, box: LookBox) -> CGImage? {
        let page = content
            .frame(width: markdownPage.width, height: markdownPage.height, alignment: .topLeading)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 1 - pageFade / markdownPage.height), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .background(palette.paper)
            .environment(\.colorScheme, palette.dark ? .dark : .light)
        let renderer = ImageRenderer(content: page)
        renderer.scale = CGFloat(box.longestSide(of: markdownPage)) / markdownPage.width
        return renderer.cgImage
    }

    /// 页底淡出的那一截：约一行半字高，切在哪一行，被切的那行都已淡到看不出
    private static let pageFade: CGFloat = 36
    /// 画成多大的一页再缩进卡片：比阅读栏窄，缩进主图、横排时字仍认得出（480 宽时列表只剩七八磅）
    static let markdownPage = CGSize(width: 360, height: 270)

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
        guard let first = await Thumbnails.system(at: file, fitting: box.fitting, scale: scale, icons: false) else { return nil }
        let longest = box.longestSide(of: CGSize(width: first.width, height: first.height))
        let image = longest > max(first.width, first.height)
            ? await Thumbnails.system(at: file, fitting: CGSize(width: longest, height: longest), scale: scale, icons: false) ?? first : first
        return await Thumbnails.shrunk(image, to: longest)
    }

    private static func duration(_ file: URL) async -> String? {
        (try? await AVURLAsset(url: file).load(.duration)).flatMap { clock($0.seconds) }
    }

    static func clock(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds.rounded()).formatted(.time(pattern: pattern))
    }
}

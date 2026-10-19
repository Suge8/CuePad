import CueStore
import SwiftUI

/// 交付物（会话发到手机看的文件）全 App 只有这一个样子，三处共用、三种尺寸（`Size`）：会话页的那张卡（`PreviewBatch`）、
/// Cue 页的结果卡（`CueResultCard`）、"等你"里的迷你一排。
/// 一份是整宽主图（按内容真实比例夹在 4:3～16:9），两份并排（各按真实比例，不高过主图），三份起横向滑、各按真实比例定宽同高，放不下的露出一截；
/// 每张下面一行"标题 · 类型（时长、页数）"，迷你一排没有这一行。缩略图全是真内容（`DeliverableLooks`）。
/// 文件还在从 iCloud 下载时画面上写"下载中"（三种尺寸都有）、点不开，到了自动换成内容。点一张交给 `open`，全屏页从这张放大出来（`previewPresenter`）。
struct DeliverableStrip: View {
    enum Size {
        case result, chat, mini
    }

    let previews: [PiPreview]
    let size: Size
    /// 同一份可能同时出现在几处（结果卡与"等你"）：放大与缩回按"哪一组 + 哪一份"认那张缩略图
    let group: String
    /// 横向滑的一排越过所在纸面的内边距、滑到纸边（纸的内边距）
    var bleed: CGFloat = 0
    let open: (PiPreview) -> Void
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        switch previews.count {
        case 0:
            EmptyView()
        case 1 where size != .mini:
            tile(previews[0], .hero(maxHeight: Self.heroMaxHeight(size)))
        case 2 where size != .mini:
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(previews) { tile($0, .column(maxHeight: Self.heroMaxHeight(size))) }
            }
        default:
            // 懒加载：一件活常常挂着几十上百份（真实库里一张结果卡 278 份），整排都建的话第一次打开 Cue 页光这一张就占 300ms 主线程。
            // 从最前面滑起、同高，只建看得见与附近的几张，位置不靠估
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.gap) {
                    ForEach(previews) { tile($0, .strip(height: stripHeight)) }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, bleed, for: .scrollContent)
            .padding(.horizontal, -bleed)
            // 这一排滑动后滚动区不裁前沿（三端实测，与内容边距、负内边距、scrollClipDisabled(false) 都无关）：滑过去的缩略图画到纸外、
            // 压在桌面上。明写裁到滚动区的框，也就是纸边
            .clipShape(.rect)
        }
    }

    private func tile(_ preview: PiPreview, _ shape: DeliverableTile.Shape) -> some View {
        DeliverableTile(
            preview: preview, label: Self.label(of: preview, in: previews), shape: shape, captioned: size != .mini,
            zoom: PreviewZoomKey(group: group, preview: preview.id), open: open)
    }

    static let gap: CGFloat = 8

    /// 在 `width` 宽里至少多高（Cue 页打开时数铺满一屏要排几格，`CuePage.floor`）：一份是主图，比例最扁到 16:9；两份各按真实比例，
    /// 可能扁得几乎没有高；三份起是定高的一排。图下面那行字至少一行小字。
    static func floor(count: Int, size: Size, width: CGFloat) -> CGFloat {
        let caption: CGFloat = size == .mini ? 0 : DeliverableTile.captionGap + 12
        switch count {
        case 0: return 0
        case 1 where size != .mini: return min(heroMaxHeight(size), width * 9 / 16) + caption
        case 2 where size != .mini: return caption
        default: return stripHeight(size, regular: false) + caption
        }
    }

    private var stripHeight: CGFloat {
        #if os(macOS)
        Self.stripHeight(size, regular: true)
        #else
        Self.stripHeight(size, regular: sizeClass == .regular)
        #endif
    }

    /// 三份起那一排的高；`regular`：宽屏（iPad），卡宽得多，迷你一排与 Mac 同高。
    private static func stripHeight(_ size: Size, regular: Bool) -> CGFloat {
        switch size {
        #if os(macOS)
        case .mini: 88
        case .result: 200
        case .chat: 176
        #else
        case .mini: regular ? 88 : 72
        case .result: 150
        case .chat: 132
        #endif
        }
    }

    private static func heroMaxHeight(_ size: Size) -> CGFloat {
        #if os(macOS)
        size == .result ? 360 : 320
        #else
        size == .result ? 300 : 260
        #endif
    }

    /// 一份在缩略图下与全屏页顶上的写法：几份同一个标题（一次发的几个共用 `--title`）时写各自的文件名，否则写标题。
    static func label(of preview: PiPreview, in previews: [PiPreview]) -> String {
        guard previews.contains(where: { $0.id != preview.id && $0.title == preview.title }) else { return preview.title }
        return ((preview.name as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// 几份共用的标题（会话页那张卡写在最上面）；一份或各有各的标题时为 nil。
    static func heading(_ previews: [PiPreview]) -> String? {
        guard previews.count > 1, let title = previews.first?.title, previews.allSatisfy({ $0.title == title }) else { return nil }
        return title
    }
}

/// 放大与缩回认的那张缩略图。
struct PreviewZoomKey: Hashable {
    let group: String
    let preview: UUID
}

extension EnvironmentValues {
    /// 全屏页从哪个命名空间里找缩略图放大（`previewPresenter` 给，手机才有）。
    @Entry var previewZoom: Namespace.ID?
}

/// 交付物的一张：画面（按比例）与下面一行字。
struct DeliverableTile: View {
    enum Shape {
        /// 整宽，比例夹在 4:3～16:9，不高过 `maxHeight`
        case hero(maxHeight: CGFloat)
        /// 并排的几份之一：各占等宽的一份，不高过 `maxHeight`
        case column(maxHeight: CGFloat)
        /// 横向滑的一排里：同高，宽按比例
        case strip(height: CGFloat)
        /// 提问点名的图（`CueShots`）：同高、宽按比例、整张不裁，白底、实色边（`Palette.mediaEdge`）、深色下不压暗，
        /// 右上角一颗放大的记号（太窄的不放，Mac 上悬停才出现）。`aspect` 是读到画面之前已知的比例（图片的像素尺寸，`CueShown.aspect`）。
        case shot(height: CGFloat, aspect: CGFloat?)
    }

    /// 画面与下面那行字之间。
    static let captionGap: CGFloat = 5

    let preview: PiPreview
    let label: String
    let shape: Shape
    let captioned: Bool
    let zoom: PreviewZoomKey
    let open: (PiPreview) -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @Environment(\.previewZoom) private var namespace
    /// 文件随同步到本机的那一刻就绪（附件表变化时重读）
    @State private var arrived: Bool?
    @State private var look: DeliverableLook?
    @State private var located = Located()
    @State private var hovering = false

    /// 本机的那份文件（`AttachmentFiles.url(of:)` 要查几次文件系统，第一次还要拷一份）：同一次"到没到"只找一次，
    /// 视图体里用到它的几处不再各找一遍。
    private var file: URL? {
        if located.arrived != .some(arrived) {
            located.arrived = arrived
            located.url = arrived == false ? nil : services.store.files.url(of: preview)
        }
        return located.url
    }

    private final class Located {
        var arrived: Bool??
        var url: URL?
    }

    var body: some View {
        Button { open(preview) } label: {
            VStack(alignment: .leading, spacing: Self.captionGap) {
                framed
                if captioned { caption }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .disabled(file == nil)
        .accessibilityLabel(Dotted("预览：\(label)", kind).spoken)
        .accessibilityHint(file == nil ? "正在从 iCloud 下载" : "全屏查看")
        #if os(macOS)
        .help(label)
        #endif
        .observingArrival(of: preview.hash, in: services.store, into: $arrived)
        .task(id: file) {
            guard let file else { return }
            look = await DeliverableLooks.load(preview, file: file, box: box, scale: scale, caches: services.store.files.caches)
        }
    }

    /// 类型，视频与音频接时长、PDF 接页数："视频 0:12""PDF 3 页"。
    private var kind: String {
        [preview.kind?.label ?? "文件", shown?.detail].compactMap { $0 }.joined(separator: " ")
    }

    /// 读到之前先从内存里拿（同一份别处读过、滚回来的），第一帧就是该有的比例。
    private var shown: DeliverableLook? { look ?? DeliverableLooks.cached(preview, box: box) }

    private var aspect: CGFloat {
        // 读到之前按类型猜：PDF 多是竖着的一页，其余（网页、截图、文稿的首屏）多是横的；猜对了读到时不跳
        let raw = shown?.aspect ?? Self.guessedAspect(preview, known: shotAspect)
        guard case .hero = shape else { return raw }
        return min(max(raw, 4 / 3), 16 / 9)
    }

    /// 读到画面之前的比例：已知的（图片的像素尺寸）照用，否则按类型猜——PDF 多是竖着的一页，其余（网页、截图、文稿的首屏）多是横的；猜对了读到时不跳。
    nonisolated static func guessedAspect(_ preview: PiPreview, known: CGFloat?) -> CGFloat { known ?? (preview.kind == .pdf ? 3 / 4 : 4 / 3) }

    private var shotAspect: CGFloat? { if case .shot(_, let aspect) = shape { aspect } else { nil } }
    private var isShot: Bool { if case .shot = shape { true } else { false } }

    /// 放大的记号：图宽到这么多才放（再窄就挡住了图）。
    static let enlargeMinWidth: CGFloat = 80

    /// 画面出来之前写它是什么：成页的（网页、文稿、表格、PDF…）一张纸，音频、视频、3D 各自的记号，其余是文件。
    private var kindIcon: Icon {
        switch preview.kind {
        case .audio: .audio
        case .video: .play
        case .model: .inspect3D
        case .image, nil: .file
        case .web, .markdown, .pdf, .document, .spreadsheet, .presentation, .text: .document
        }
    }

    private var radius: CGFloat {
        switch shape {
        case .strip(let height) where height < 80: 8
        case .shot: 10
        default: 12
        }
    }

    @ViewBuilder private var framed: some View {
        switch shape {
        case .hero(let maxHeight):
            picture.aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
        case .column(let maxHeight):
            picture.aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .leading)
        case .strip(let height):
            picture.frame(width: (height * aspect).rounded(), height: height)
        case .shot(let height, _):
            let width = (height * aspect).rounded()
            picture.frame(width: width, height: height)
                .overlay(alignment: .topTrailing) { if width >= Self.enlargeMinWidth { enlarge } }
                #if os(macOS)
                .onHover { inside in withAnimation(Motion.quick) { hovering = inside } }
                #endif
        }
    }

    /// 右上角的放大记号：只是提示，整张图都可点。
    private var enlarge: some View {
        Image(.enlarge).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.onMedia)
            .frame(width: 20, height: 20).background(palette.mediaScrim, in: .circle)
            .padding(6)
            #if os(macOS)
            .opacity(hovering ? 1 : 0)
            #endif
            .accessibilityHidden(true)
    }

    /// 画面铺满给的框（比例夹过的多出来的裁掉）；没有画面的写类型。
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // 裁的时候留上沿：截图与页面要紧的多在上面
        // 要你看清的图垫白（透明图）；画面出来之前同别处，写它是什么
        return Rectangle().fill(isShot && shown?.image != nil ? Color.white : palette.fill)
            .overlay(alignment: .top) {
                if let image = shown?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        // 深色下页面与截图多是亮底，原样放在暗纸上刺眼：压暗一层（同 `Thumbnail`）；要你看清的图不压
                        .overlay { if preview.kind != .video, !isShot { palette.mediaDim } }
                } else if file == nil {
                    // 还没到本机：迷你一排没有下面那行字，下载中写在画面上
                    VStack(spacing: 3) {
                        Image(.downloading).font(.callout)
                        Text("下载中").font(Typography.caption)
                    }
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 画面还在出（或这种文件没有画面）：写它是什么，不留一块空白
                    VStack(spacing: 4) {
                        Image(kindIcon).font(radius < 12 ? .callout : .title2)
                        if preview.kind == .audio, let detail = shown?.detail { Text(detail).font(Typography.caption).monospacedDigit() }
                    }
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if preview.kind == .video, shown?.image != nil {
                    Image(.play).font(.caption.weight(.bold)).foregroundStyle(palette.onMedia)
                        .padding(7).background(palette.mediaScrim, in: .circle).padding(8)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isShot ? palette.mediaEdge : palette.hair))
            .zoomSource(zoom, in: namespace)
    }

    private var caption: some View {
        Group {
            if file == nil {
                Text("正在从 iCloud 下载…").foregroundStyle(palette.ink3)
            } else {
                Text("\(Text(label).foregroundStyle(palette.ink2))\(Dotted.inline)\(Text(kind))").foregroundStyle(palette.ink3)
            }
        }
        .font(Typography.caption).monospacedDigit().lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画面的框（像素，见 `framed`）：主图的比例夹在 4:3～16:9、不高过上限，所以宽不过上限的 16/9，夹过的多出来的裁掉；
    /// 并排的按真实比例整张放进半栏（阅读栏约 760 点）、不高过上限；横向滑的一排同高、宽随比例。
    private var box: LookBox {
        let pixels = { (points: CGFloat) in Int(points * scale) }
        return switch shape {
        case .hero(let maxHeight): LookBox(width: pixels(maxHeight * 16 / 9), height: pixels(maxHeight), fills: true)
        case .column(let maxHeight): LookBox(width: pixels(380), height: pixels(maxHeight), fills: false)
        case .strip(let height), .shot(let height, _): LookBox(width: 0, height: pixels(height), fills: true)
        }
    }
}

private extension View {
    @ViewBuilder func zoomSource(_ key: PreviewZoomKey, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace { matchedTransitionSource(id: key, in: namespace) } else { self }
        #else
        self
        #endif
    }
}

/// 会话页里 Agent 一次发来看的几个（同一时刻的一批）：一张纸，几份共用的标题写在最上面，下面是交付物。
struct PreviewBatch: View {
    let previews: [PiPreview]
    let group: String
    let open: (PiPreview) -> Void
    @Environment(\.palette) private var palette

    private static let inset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading = DeliverableStrip.heading(previews) {
                Text(heading).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            DeliverableStrip(previews: previews, size: .chat, group: group, bleed: Self.inset, open: open)
        }
        .padding(Self.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 16)
    }
}

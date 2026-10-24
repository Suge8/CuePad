import CueStore
import SwiftUI

/// 会话页里 Agent 一次发来看的几个（同一时刻的一批，`PiChat.entries`）：一张纸，上面是交付物；会话发到手机的文件在会话页里只有这一个样子。
/// Cue 点名的图（提问卡、结果卡）是另一种：方形缩略图配看什么（`CueShots`），共用一张一张的 `DeliverableTile`。
/// 一份是整宽主图（按内容真实比例夹在 4:3～16:9），两份并排（各按真实比例，不高过主图），三份起横向滑、各按真实比例定宽同高，放不下的露出一截；
/// 每张下面写它的标题（Agent 发时每份一句、同批各不相同，至多两行）与类型（时长、页数）。缩略图全是真内容（`DeliverableLooks`）。
/// 文件还在从 iCloud 下载时画面上写"下载中"、点不开，到了自动换成内容。点一张交给 `open`，全屏页从这张放大出来（`previewPresenter`）。
struct PreviewBatch: View {
    let previews: [PiPreview]
    /// 放大与缩回按"哪一组 + 哪一份"认那张缩略图
    let group: String
    let open: (PiPreview) -> Void

    var body: some View {
        strip
            .padding(Self.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
    }

    @ViewBuilder private var strip: some View {
        switch previews.count {
        case 1:
            tile(previews[0], .hero(maxHeight: Self.heroMaxHeight))
        case 2:
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(previews) { tile($0, .column(maxHeight: Self.heroMaxHeight)) }
            }
        default:
            // 懒加载：一个会话一次可能发几十份，只建看得见与附近的几张。从最前面滑起、同高，位置不靠估；越过纸的内边距滑到纸边
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.gap) {
                    ForEach(previews) { tile($0, .strip(height: Self.stripHeight)) }
                }
            }
            .scrollIndicators(.hidden)
            .safeAreaPadding(.horizontal, Self.inset)
            .padding(.horizontal, -Self.inset)
            // 这一排滑动后滚动区不裁前沿（三端实测，与内容边距、负内边距、scrollClipDisabled(false) 都无关）：滑过去的缩略图画到纸外、
            // 压在桌面上。明写裁到滚动区的框，也就是纸边
            .clipShape(.rect)
        }
    }

    private func tile(_ preview: PiPreview, _ shape: DeliverableTile.Shape) -> some View {
        DeliverableTile(
            preview: preview, label: preview.title, shape: shape, captioned: true, zoom: PreviewZoomKey(group: group, preview: preview.id), open: open)
    }

    nonisolated static let gap: CGFloat = 8
    private static let inset: CGFloat = 12

    #if os(macOS)
    private static let stripHeight: CGFloat = 176
    private static let heroMaxHeight: CGFloat = 320
    #else
    private static let stripHeight: CGFloat = 132
    private static let heroMaxHeight: CGFloat = 260
    #endif
}

struct PreviewZoomKey: Hashable {
    let group: String
    let preview: UUID
}

extension EnvironmentValues {
    /// 全屏页从哪个命名空间里找缩略图放大（`previewPresenter` 给，手机才有）。
    @Entry var previewZoom: Namespace.ID?
}

/// 交付物的一张：画面（按比例）与下面的标题、类型。
struct DeliverableTile: View {
    enum Shape {
        /// 整宽，比例夹在 4:3～16:9，不高过 `maxHeight`
        case hero(maxHeight: CGFloat)
        /// 并排的几份之一：各占等宽的一份，不高过 `maxHeight`
        case column(maxHeight: CGFloat)
        /// 横向滑的一排里：同高，宽按比例
        case strip(height: CGFloat)
        /// 提问点名的图（`CueShots`）：方形、宽随给的（至多 `side`）、取细节最多的那一段填满（`LookBox.framed`），白底、实色边（`Palette.mediaEdge`）、深色下不压暗，
        /// 图上不压放大记号（整张都可点，记号挡的正是要认的内容）。`chosen`："可以"选的就是这张，边换成两点宽的主按钮靛青。
        case shot(side: CGFloat, chosen: Bool)
    }

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
    /// 画面出了 `Pending.delay` 还没出来：这时才写它是什么（`kindIcon`）。
    @State private var slow = false
    @State private var located = Located()

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
            let waited = shown == nil
            let loaded = await DeliverableLooks.load(preview, file: file, box: box, scale: scale, caches: services.store.files.caches)
            withAnimation(waited ? HandOff.quick : nil) { look = loaded }
        }
        .pending(loading, shown: $slow)
    }

    /// 类型，视频与音频接时长、PDF 接页数："视频 0:12""PDF 3 页"。
    private var kind: String {
        [preview.kind?.label ?? "文件", shown?.detail].compactMap { $0 }.joined(separator: " ")
    }

    /// 读到之前先从内存里拿（同一份别处读过、滚回来的），第一帧就是该有的比例。
    private var shown: DeliverableLook? { look ?? DeliverableLooks.cached(preview, box: box) }

    private var aspect: CGFloat {
        // 读到之前按类型猜：PDF 多是竖着的一页，其余（网页、截图、文稿的首屏）多是横的；猜对了读到时不跳
        let raw = shown?.aspect ?? (preview.kind == .pdf ? 3 / 4 : 4 / 3)
        guard case .hero = shape else { return raw }
        return min(max(raw, 4 / 3), 16 / 9)
    }

    /// 文件在本机、画面还没读到（内存里没有，在读磁盘上那份或现出）。
    private var loading: Bool { file != nil && shown == nil }

    private var isShot: Bool { if case .shot = shape { true } else { false } }
    private var isChosen: Bool { if case .shot(_, true) = shape { true } else { false } }

    /// 画面出得慢（过了 `Pending.delay`）或出不来时写它是什么：成页的（网页、文稿、表格、PDF…）一张纸，音频、视频、3D 各自的记号，其余是文件。
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
        case .strip(let height) where height < 30: 4
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
        case .shot:
            picture.aspectRatio(1, contentMode: .fit)
        }
    }

    /// 画面铺满给的框（比例夹过的多出来的裁掉）；没有画面的写类型。
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // 裁的时候留上沿：截图与页面要紧的多在上面；提问的方形缩略图出画面时已取好景（`LookBox.framed`），居中放
        // 要你看清的图垫白（透明图）。画面还在读时先空着（只有边），读到了淡入；读了 `Pending.delay` 还没出来才铺底写它是什么：
        // 新到的一张（结果卡、提问卡插进对话）几十毫秒就出来，先闪一帧灰底加文件图标再换成截图，比空一下更扰人
        let waiting = loading && !slow
        let ground: Color = switch (shown?.image != nil, isShot, waiting) {
        case (true, true, _): palette.mediaGround
        case (false, _, true): .clear
        default: palette.fill
        }
        return Rectangle().fill(ground)
            .overlay(alignment: isShot ? .center : .top) {
                if let image = shown?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        // 深色下页面与截图多是亮底，原样放在暗纸上刺眼：压暗一层（同 `Thumbnail`）；要你看清的图不压
                        .overlay { if preview.kind != .video, !isShot { palette.mediaDim } }
                        .transition(.opacity)
                } else if waiting {
                    EmptyView()
                } else if file == nil {
                    // 还没到本机：点名的图没有下面那行字，下载中写在画面上
                    VStack(spacing: 3) {
                        Image(.downloading).font(.callout)
                        Text("下载中").font(Typography.caption)
                    }
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 画面出得慢（或这种文件没有画面）：写它是什么
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
            .overlay(shape.strokeBorder(isChosen ? palette.signatureFill : isShot ? palette.mediaEdge : palette.hair, lineWidth: isChosen ? 2 : 1))
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
        .font(Typography.caption).monospacedDigit().lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 画面的框（像素，见 `framed`）：主图的比例夹在 4:3～16:9、不高过上限，所以宽不过上限的 16/9，夹过的多出来的裁掉；
    /// 并排的按真实比例整张放进半栏（阅读栏约 760 点）、不高过上限；横向滑的一排同高、宽随比例。
    private var box: LookBox {
        let pixels = { (points: CGFloat) in Int(points * scale) }
        return switch shape {
        case .hero(let maxHeight): LookBox(width: pixels(maxHeight * 16 / 9), height: pixels(maxHeight), fills: true)
        case .column(let maxHeight): LookBox(width: pixels(380), height: pixels(maxHeight), fills: false)
        case .strip(let height): LookBox(width: 0, height: pixels(height), fills: true)
        case .shot(let side, _): LookBox(width: pixels(side), height: pixels(side), fills: true, framed: true)
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

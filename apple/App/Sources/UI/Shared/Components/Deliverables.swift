import CueStore
import SwiftUI

struct PreviewBatch: View {
    let previews: [PreviewItem]
    let group: String
    let reply: (PreviewItem) -> Void
    let open: (PreviewItem) -> Void

    var body: some View {
        strip
            .padding(Self.inset)
            .frame(maxWidth: previews.count > 2 ? .infinity : nil, alignment: .leading)
            .paper()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var strip: some View {
        switch previews.count {
        case 1, 2:
            PreviewRow(maxHeight: Self.rowHeight, gap: Self.gap) {
                ForEach(previews) { tile($0, previews.count == 1 ? .hero : .column) }
            }
        default:
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

    private func tile(_ preview: PreviewItem, _ shape: DeliverableTile.Shape) -> some View {
        DeliverableTile(
            preview: preview, label: preview.title, shape: shape, captioned: true, zoom: PreviewZoomKey(group: group, preview: preview.id), open: open)
        .contextMenu { Button("回复", icon: .reply) { reply(preview) }.menuIcons() }
    }

    nonisolated static let gap = Spacing.item
    private static let inset = Spacing.group

    #if os(macOS)
    private static let stripHeight: CGFloat = 176
    static let rowHeight: CGFloat = 320
    #else
    private static let stripHeight: CGFloat = 132
    static let rowHeight: CGFloat = 260
    #endif
}

struct PreviewZoomKey: Hashable {
    let group: String
    let preview: UUID
}

extension EnvironmentValues {
    @Entry var previewZoom: Namespace.ID?
}

struct DeliverableTile: View {
    enum Shape {
        case hero
        case column
        case strip(height: CGFloat)
        case shot(side: CGFloat)
    }

    static let captionGap = Spacing.tight

    let preview: PreviewItem
    let label: String
    let shape: Shape
    let captioned: Bool
    let zoom: PreviewZoomKey
    let open: (PreviewItem) -> Void
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var place = AttachmentPlace.unchecked
    @State private var look: DeliverableLook?
    @State private var slow = false

    private var file: URL? { place.file(preview.key, in: services.store.files) }

    var body: some View {
        Button { if file == nil { workspace.fetchFile(preview.key) } else { open(preview) } } label: {
            VStack(alignment: .leading, spacing: Self.captionGap) {
                framed
                if captioned { caption }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityLabel(Dotted(String(localized: "预览：\(label)"), kind).spoken)
        .accessibilityHint(file == nil ? "从 iCloud 取来" : "全屏查看")
        #if os(macOS)
        .help(label)
        #endif
        .observingArrival(of: preview.key, in: services, into: $place)
        .task(id: file) {
            guard let file else { return }
            let waited = shown == nil
            let loaded = await DeliverableLooks.load(preview, file: file, box: box, scale: scale, caches: services.store.files.caches)
            withAnimation(waited ? Motion.fade : nil) { look = loaded }
        }
        .task(id: loading) {
            if loading { try? await Task.sleep(for: Pending.delay) }
            guard !Task.isCancelled, slow != loading else { return }
            withAnimation(Motion.fade) { slow = loading }
        }
        .debugSettling(loading)
        .layoutValue(key: PreviewAspect.self, value: aspect)
    }

    private var kind: String {
        [preview.kind?.label ?? String(localized: "文件"), shown?.detail].compactMap { $0 }.joined(separator: " ")
    }

    private var shown: DeliverableLook? { look ?? DeliverableLooks.cached(preview, box: box) }

    private var aspect: CGFloat {
        let raw = shown?.aspect ?? (preview.kind == .pdf ? 3 / 4 : 4 / 3)
        return switch shape {
        case .hero: min(max(raw, 4 / 3), 16 / 9)
        case .column: min(max(raw, 1 / 2), 2)
        case .strip, .shot: raw
        }
    }

    private var loading: Bool { file != nil && shown == nil }

    private var isShot: Bool { if case .shot = shape { true } else { false } }

    private var kindIcon: Icon { Self.icon(preview.kind) }

    static func icon(_ kind: PreviewKind?) -> Icon {
        switch kind {
        case .audio: .audio
        case .video: .play
        case .model: .inspect3D
        case .image, nil: .file
        case .web, .markdown, .pdf, .document, .spreadsheet, .presentation, .diff, .text: .document
        }
    }

    private var radius: CGFloat {
        switch shape {
        case .strip(let height) where height < 80: Radius.chip
        default: Radius.block
        }
    }

    @ViewBuilder private var framed: some View {
        switch shape {
        case .hero, .column:
            picture.aspectRatio(aspect, contentMode: .fit)
        case .strip(let height):
            picture.frame(width: (height * aspect).rounded(), height: height)
        case .shot:
            picture.aspectRatio(1, contentMode: .fit)
        }
    }

    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let waiting = loading && !slow
        let crop: Alignment = isShot ? .center : .top
        let ground: Color = switch (shown?.image != nil, isShot, waiting) {
        case (true, true, _): palette.mediaGround
        case (false, _, true): .clear
        default: palette.fill
        }
        return Rectangle().fill(ground)
            .overlay(alignment: crop) {
                if let image = shown?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .overlay { if preview.kind != .video, !isShot, !DeliverableLooks.drawn(preview.kind) { palette.mediaDim } }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if waiting {
                    EmptyView()
                } else if file == nil {
                    VStack(spacing: Spacing.tight) {
                        Image(.downloading).font(Glyph.control)
                        Text(verbatim: AttachmentLooks.awayLine(preview.key, services)).font(Typography.caption).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, Spacing.tight)
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: Spacing.tight) {
                        Image(kindIcon).font(radius < Radius.block ? Glyph.control : Glyph.large)
                        if preview.kind == .audio, let detail = shown?.detail { Text(detail).font(Typography.caption) }
                    }
                    .foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if preview.kind == .video, shown?.image != nil {
                    Image(.play).font(Glyph.small).foregroundStyle(palette.onMedia)
                        .padding(Spacing.item).background(palette.mediaScrim, in: .circle).padding(Spacing.item)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isShot ? palette.mediaEdge : palette.hair, lineWidth: 1))
            .previewSource(zoom, cornerRadius: radius, aspect: isShot ? nil : shown?.aspect, crop: isShot ? .detail : .aligned(crop)) { [image = shown?.image, whole] in
                await whole?() ?? image
            }
    }

    private var whole: (() async -> CGImage?)? {
        guard case .shot(let side) = shape else { return nil }
        return { [files = services.store.files, hash = preview.key, scale] in await Thumbnail.picture(hash, height: side, scale: scale, in: files) }
    }

    private var caption: some View {
        Group {
            if file == nil {
                Text(verbatim: AttachmentLooks.awayLine(preview.key, services)).foregroundStyle(palette.ink3)
            } else {
                Text("\(Text(label).foregroundStyle(palette.ink2))\(Dotted.inline)\(Text(kind))").foregroundStyle(palette.ink3)
            }
        }
        .font(Typography.caption).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var box: LookBox {
        let pixels = { (points: CGFloat) in Int(points * scale) }, row = PreviewBatch.rowHeight
        return switch shape {
        case .hero: LookBox(width: pixels(row * 16 / 9), height: pixels(row), fills: true, dark: palette.dark)
        case .column: LookBox(width: pixels(row * 2), height: pixels(row), fills: false, dark: palette.dark)
        case .strip(let height): LookBox(width: 0, height: pixels(height), fills: true, dark: palette.dark)
        case .shot(let side): LookBox(width: pixels(side), height: pixels(side), fills: true, framed: true)
        }
    }
}

extension View {
    func previewSource(
        _ key: PreviewZoomKey, cornerRadius: CGFloat, aspect: CGFloat? = nil, crop: PreviewCrop = .aligned(.center), image: @escaping () async -> CGImage?
    ) -> some View {
        modifier(PreviewSource(key: key, radius: cornerRadius, aspect: aspect, crop: crop, image: image))
    }
}

enum PreviewCrop {
    case aligned(Alignment)
    case detail
}

private struct PreviewSource: ViewModifier {
    let key: PreviewZoomKey
    let radius: CGFloat
    let aspect: CGFloat?
    let crop: PreviewCrop
    let image: () async -> CGImage?
    #if os(iOS)
    @Environment(\.previewZoom) private var namespace
    @Environment(\.previewSources) private var sources
    #else
    @Environment(\.previewFlight) private var flight
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: key, in: namespace)
                .onAppear(perform: register)
                .onChange(of: aspect, register)
        } else {
            content
        }
        #else
        if let flight {
            content.background { PreviewSourceMark(flight: flight, key: key, image: image, aspect: aspect, radius: radius, crop: crop) }
        } else {
            content
        }
        #endif
    }

    #if os(iOS)
    private func register() { sources?.register(key, .init(aspect: aspect, image: image)) }
    #endif
}

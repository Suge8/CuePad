import CueStore
import SwiftUI

/// 回复框玻璃里、输入区上面的批注（`ComposerDraft.notes`，按在对话里的先后）：与带上的灵感同一种淡底圆角块，一条一行——
/// 左边一道次墨色短竖条，先是批注，后面淡淡的「摘录」；引用的预览行首是它的小缩略图（`QuoteThumb`，按编号取），后面一句"预览「标题」"（话在回复框里写）。
/// 点一条回到原文（引用的回到对话里那一批预览）；× 删掉（Mac 悬停时才露出，触屏上常显）。批注只存在本机。
/// 多于 `shown` 条时这一块定高、可滚，不把对话挤走。改批注在对话里点那处高亮。
struct ReplyNoteStack: View {
    let notes: [ReplyNote]
    /// 这个会话此刻的预览：引用的那一行按编号取缩略图（`ReplyNote.quoted`）。
    let previews: [PiPreview]
    /// 回到原文（会话页给）。
    let reveal: (ReplyNote) -> Void
    let remove: (ReplyNote) -> Void
    @Environment(\.palette) private var palette

    private static let shown = 4
    private static let shape = Radius.nested

    var body: some View {
        Group {
            if notes.count > Self.shown {
                // 多露半行：看得出还能往下滚
                ScrollView { rows }.frame(height: (CGFloat(Self.shown) + 0.5) * NoteRow.height + 2 * Self.pad)
            } else {
                rows
            }
        }
        .background(palette.fill, in: Self.shape)
        .padding([.horizontal, .top], ComposerMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notes.count) 条批注，随下一句发出")
    }

    private static let pad = Spacing.tight

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
                NoteRow(note: note, quoted: note.quoted(in: previews), reveal: { reveal(note) }, remove: { remove(note) }).transition(.opacity)
            }
        }
        .padding(.vertical, Self.pad)
    }
}

private struct NoteRow: View {
    let note: ReplyNote
    let quoted: PiPreview?
    let reveal: () -> Void
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    #if os(iOS)
    static let height: CGFloat = 40
    /// 触屏没有悬停：× 常显，按得着的宽度够一根手指。
    private static let alwaysShowsRemove = true, removeWidth: CGFloat = 44
    #else
    static let height: CGFloat = 30
    private static let alwaysShowsRemove = false, removeWidth = height
    #endif

    var body: some View {
        HStack(spacing: 0) {
            Button(action: reveal) {
                HStack(spacing: Spacing.item) {
                    if note.preview != nil {
                        QuoteThumb(preview: quoted, kind: note.kind)
                        Text("预览「\(note.quote)」").font(Typography.secondary).foregroundStyle(palette.ink2)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Capsule().fill(palette.ink2).frame(width: 3, height: 14)
                        Text(note.note).font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(1)
                            .layoutPriority(1)
                        Text("「\(ReplyNote.excerpt(note.quote))」").font(Typography.caption).foregroundStyle(palette.ink3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, Spacing.group)
                .frame(minHeight: Self.height).contentShape(.rect)
            }
            .buttonStyle(PressStyle(.wide))
            .help(Text(revealHint))
            .accessibilityLabel(note.preview == nil ? Text("批注：\(note.note)，原文：\(ReplyNote.excerpt(note.quote))") : Text("引用预览：\(note.quote)"))
            .accessibilityHint(Text(revealHint))
            Button(action: remove) {
                Image(.remove).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .frame(width: Self.removeWidth, height: Self.height).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .opacity(Self.alwaysShowsRemove || hovering ? 1 : 0)
            .accessibilityLabel(Text(removeLabel))
            .help(Text(removeLabel))
        }
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }

    private var revealHint: LocalizedStringResource { note.preview == nil ? "回到原文" : "回到这份预览" }
    private var removeLabel: LocalizedStringResource { note.preview == nil ? "删掉这条批注" : "不引用这份预览" }
}

/// 引用那一行行首的小图：按编号取到的那份预览的画面（同会话里的缩略图一套 `DeliverableLooks`，草稿里不存图）。
/// 文件还没到本机、画面还没出来或这种文件没有画面时写它的类型（`DeliverableTile.icon`）；预览已随对话过期、取不到时照引用时记下的类型（`ReplyNote.kind`）。
private struct QuoteThumb: View {
    let preview: PiPreview?
    let kind: PiPreviewKind?
    @Environment(\.palette) private var palette

    #if os(iOS)
    static let side: CGFloat = 28
    #else
    static let side: CGFloat = 22
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip)
        Group {
            if let preview { Picture(preview: preview) } else { Self.mark(DeliverableTile.icon(kind), palette) }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.hair))
        .accessibilityHidden(true) // 合并在这一行的按钮里，按钮的标签已说是哪份预览
    }

    static func mark(_ icon: Icon, _ palette: Palette) -> some View {
        palette.fill.overlay { Image(icon).font(Glyph.small).foregroundStyle(palette.ink3) }
    }

    private struct Picture: View {
        let preview: PiPreview
        @Environment(AppServices.self) private var services
        @Environment(\.palette) private var palette
        @Environment(\.displayScale) private var scale
        @State private var place = AttachmentPlace.unchecked
        @State private var image: CGImage?

        var body: some View {
            Group {
                if let image {
                    // 同会话里的缩略图：留上沿，深色下截图与网页压暗一层
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: QuoteThumb.side, height: QuoteThumb.side, alignment: .top)
                        .overlay { if preview.kind != .video, !DeliverableLooks.drawn(preview.kind) { palette.mediaDim } }
                } else {
                    QuoteThumb.mark(DeliverableTile.icon(preview.kind), palette)
                }
            }
            .observingArrival(of: preview.key, in: services, into: $place)
            .task(id: place.file(preview.key, in: services.store.files)) {
                guard let file = place.file(preview.key, in: services.store.files) else { return }
                let pixels = Int(QuoteThumb.side * scale)
                image = await DeliverableLooks.load(
                    preview, file: file, box: LookBox(width: pixels, height: pixels, fills: true, dark: palette.dark), scale: scale, caches: services.store.files.caches
                ).image
            }
        }
    }
}

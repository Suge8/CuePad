import CueStore
import SwiftUI

struct ReplyNoteStack: View {
    let notes: [ReplyNote]
    let previews: [PreviewItem]
    let reveal: (ReplyNote) -> Void
    let remove: (ReplyNote) -> Void
    @Environment(\.palette) private var palette

    private static let shown = 4
    private static let shape = Radius.nested

    var body: some View {
        ReplyNoteLayout(limit: (CGFloat(Self.shown) + 0.5) * NoteRow.height) {
            ViewThatFits(in: .vertical) {
                rows.fixedSize(horizontal: false, vertical: true)
                ScrollView { rows }
            }
        }
        .background(palette.fill, in: Self.shape)
        .clipShape(Self.shape).rowContainer(.rect(cornerRadius: Radius.block), flush: true)
        .padding([.horizontal, .top], ComposerMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notes.count) 条批注，随下一句发出")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
                NoteRow(note: note, quoted: note.quoted(in: previews), reveal: { reveal(note) }, remove: { remove(note) }).transition(.opacity)
            }
        }
    }
}

private struct ReplyNoteLayout: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, limit, proposal.height ?? limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct NoteRow: View {
    let note: ReplyNote
    let quoted: PreviewItem?
    let reveal: () -> Void
    let remove: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(iOS)
    static let height: CGFloat = 40
    #else
    static let height: CGFloat = 30
    #endif

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 0) {
            Group {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
                    : AnyLayout(HStackLayout(spacing: Spacing.item))
                layout {
                    if !note.note.isEmpty {
                        Text(note.note).font(Typography.secondary).foregroundStyle(palette.ink).layoutPriority(1)
                    }
                    HStack(spacing: Spacing.glyph) {
                        if note.preview != nil { QuoteThumb(preview: quoted, kind: note.kind) }
                        if note.element != nil { QuoteThumb.mark(.pickElement, palette).frame(width: QuoteThumb.side, height: QuoteThumb.side).clipShape(.rect(cornerRadius: Radius.chip)) }
                        Text(verbatim: note.marksPassage ? ReplyNote.excerpt(note.quote) : note.quote)
                            .font(note.note.isEmpty ? Typography.secondary : Typography.caption)
                            .foregroundStyle(note.note.isEmpty ? palette.ink2 : palette.ink3)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                .padding(.leading, Spacing.group)
                .frame(minHeight: Self.height).contentShape(.rect)
            }
            .onTapGesture(perform: reveal)
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .help(revealHint)
            .accessibilityLabel(
                note.element != nil ? Text("点选的页面元素：\(note.quote)")
                    : note.preview == nil ? Text("批注：\(note.note)，原文：\(ReplyNote.excerpt(note.quote))")
                    : note.note.isEmpty ? Text("引用预览：\(note.quote)") : Text("批注：\(note.note)，预览：\(note.quote)"))
            .accessibilityHint(revealHint)
            NoteRemove(label: removeLabel, action: remove)
        }
        .row()
    }

    private var revealHint: Text {
        if let element = note.element { return Text(verbatim: element.selector) }
        return note.preview == nil ? Text("回到原文") : Text("回到这份预览")
    }

    private var removeLabel: LocalizedStringResource {
        if note.element != nil { return "不带这个元素" }
        return note.preview == nil ? "删掉这条批注" : "不引用这份预览"
    }
}

private struct NoteRemove: View {
    let label: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.rowHovered) private var hovered

    #if os(iOS)
    private static let always = true, side = CGSize(width: 44, height: NoteRow.height)
    #else
    private static let always = false, side = CGSize(width: 22, height: 22)
    #endif

    var body: some View {
        Button(action: action) {
            Image(.remove).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                .frame(width: Self.side.width, height: Self.side.height).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .frame(width: max(Self.side.width, NoteRow.height), height: NoteRow.height)
        .opacity(Self.always || hovered ? 1 : 0)
        .animation(Motion.fade, value: hovered)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

private struct QuoteThumb: View {
    let preview: PreviewItem?
    let kind: PreviewKind?
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
        let preview: PreviewItem
        @Environment(AppServices.self) private var services
        @Environment(\.palette) private var palette
        @Environment(\.displayScale) private var scale
        @State private var place = AttachmentPlace.unchecked
        @State private var image: CGImage?

        var body: some View {
            Group {
                if let image {
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

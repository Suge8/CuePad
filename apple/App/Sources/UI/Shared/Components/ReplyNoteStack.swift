import SwiftUI

/// 回复框玻璃里、输入区上面的批注（`ComposerDraft.notes`，按在对话里的先后）：与带上的灵感同一种淡底圆角块，一条一行——
/// 左边一道次墨色短竖条，先是批注，后面淡淡的「摘录」；引用的预览只有一句"预览「标题」"（话在回复框里写）。
/// 点一条回到原文（引用的回到对话里那一批预览）；× 删掉（Mac 悬停时才露出，触屏上常显）。批注只存在本机。
/// 多于 `shown` 条时这一块定高、可滚，不把对话挤走。改批注在对话里点那处高亮。
struct ReplyNoteStack: View {
    let notes: [ReplyNote]
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
                NoteRow(note: note, reveal: { reveal(note) }, remove: { remove(note) }).transition(.opacity)
            }
        }
        .padding(.vertical, Self.pad)
    }
}

private struct NoteRow: View {
    let note: ReplyNote
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
                    Capsule().fill(palette.ink2).frame(width: 3, height: 14)
                    if note.preview != nil {
                        Text("预览「\(note.quote)」").font(Typography.secondary).foregroundStyle(palette.ink2)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
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

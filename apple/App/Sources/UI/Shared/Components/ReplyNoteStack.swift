import SwiftUI

/// 回复框玻璃里、输入区上面的批注（`ComposerDraft.notes`，按在对话里的先后）：与带上的灵感同一种淡底圆角块，一条一行——
/// 左边一道签名色短竖条（对上对话里那处高亮的点线），先是批注，后面淡淡的「摘录」。点一条回到原文；× 删掉（悬停时才露出）。
/// 批注只在 Mac 上写、只存在本机，所以只按 Mac 排（手机上不会有这一块）。
/// 多于 `shown` 条时这一块定高、可滚，不把对话挤走。改批注在对话里点那处高亮。
struct ReplyNoteStack: View {
    let notes: [ReplyNote]
    /// 回到原文（Mac 会话页给）。
    let reveal: (ReplyNote) -> Void
    let remove: (ReplyNote) -> Void
    @Environment(\.palette) private var palette

    private static let shown = 4
    private static let shape = RoundedRectangle(cornerRadius: ComposerMetrics.radius - ComposerMetrics.inset, style: .continuous)

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

    private static let pad: CGFloat = 4

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

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            Button(action: reveal) {
                HStack(spacing: 10) {
                    Capsule().fill(palette.ink2).frame(width: 3, height: 14).accessibilityHidden(true)
                    Text(note.note).font(Typography.secondary).foregroundStyle(palette.ink).lineLimit(1)
                        .layoutPriority(1)
                    Text("「\(ReplyNote.excerpt(note.quote))」").font(Typography.caption).foregroundStyle(palette.ink3)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(minHeight: Self.height).contentShape(.rect)
            }
            .buttonStyle(PressStyle(.wide))
            .help("回到原文")
            .accessibilityLabel("批注：\(note.note)，原文：\(ReplyNote.excerpt(note.quote))")
            .accessibilityHint("回到原文")
            Button(action: remove) {
                Image(.remove).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .frame(width: Self.height, height: Self.height).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("删掉这条批注")
            .help("删掉这条批注")
        }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

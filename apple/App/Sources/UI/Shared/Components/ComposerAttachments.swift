import CueText
import SwiftUI

/// 输入框的外框圆角、内边距（带上的卡片的圆角与外框同心）与一个圆钮占的一格（36 的圆 + 四周的点按区与边距）。
enum ComposerMetrics {
    static let radius: CGFloat = 25
    static let inset: CGFloat = 8
    static let slot: CGFloat = 50
}

/// 带上的卡片或任务：标题、图片数，可移除（`removable`）；点一下看全文，长按是预览与"展开编辑"。
struct AttachmentChip: View {
    let outbox: Outbox
    let removable: Bool
    let open: () -> Void
    let expand: () -> Void
    let drop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        let card = CardText(outbox.content)
        let shape = RoundedRectangle(cornerRadius: ComposerMetrics.radius - ComposerMetrics.inset, style: .continuous)
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(palette.ink3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title.nonEmpty ?? "图片").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        if !card.images.isEmpty {
                            Text("\(card.images.count) 张图片").font(Typography.caption).foregroundStyle(palette.ink3)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 12).frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("带上：\(card.title.nonEmpty ?? "图片")")
            .accessibilityHint("看全文")
            if removable {
                Button("不带了", systemImage: "xmark", action: drop)
                    .labelStyle(.iconOnly).foregroundStyle(palette.ink3)
                    .frame(width: 44, height: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
        }
        .background(palette.fill, in: shape)
        .attachmentContextMenu(outbox, shape: shape) {
            if removable {
                Button("展开编辑", systemImage: "text.cursor", action: expand)
                Button("不带了", systemImage: "xmark", role: .destructive, action: drop)
            }
        }
    }
}

/// 图片条：选来的图片，每张右上角可移除。
struct ImageStrip: View {
    @Binding var images: [PickedImage]
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        image.preview.resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.hair))
                        Button { images.removeAll { $0.id == image.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55)).font(.body)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除这张图片")
                    }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }
}

/// 带上的卡片或任务的全文：文字、图片按原来的顺序，分割线是一条细线。`omitsTitle`：标题已写在面板顶上时正文从标题之后开始。
/// `height` 报出内容的高度，面板按它定高。
struct AttachmentBody: View {
    let content: String
    var omitsTitle = false
    var height: Binding<CGFloat>?
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = Self.blocks(content, omitsTitle: omitsTitle)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): Text(text).font(Typography.body).foregroundStyle(palette.ink).textSelection(.enabled)
                    case .image(let hash): Thumbnail(hash: hash, height: 220, radius: 12)
                    case .split: Rectangle().fill(palette.hair).frame(height: 1)
                    }
                }
            }
            .padding(blocks.isEmpty ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height?.wrappedValue = $0 }
        }
        .background(palette.paper)
    }

    /// 相邻的文字并成一段，图片与分割线各成一块；去掉标题时删掉正文开头的标题那一行。
    private static func blocks(_ content: String, omitsTitle: Bool) -> [CueToken] {
        var blocks: [CueToken] = []
        for token in CueFormat.parse(content) {
            if case .text(let text) = token, case .text(let previous)? = blocks.last {
                blocks[blocks.count - 1] = .text(previous + text)
            } else {
                blocks.append(token)
            }
        }
        if omitsTitle, case .text(let first)? = blocks.first {
            let title = CardText(content).title
            var lines = first.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let index = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
               lines[index].trimmingCharacters(in: .whitespaces) == title {
                lines.remove(at: index)
                blocks[0] = .text(lines.joined(separator: "\n"))
            }
        }
        return blocks.compactMap { block in
            guard case .text(let text) = block else { return block }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }
}

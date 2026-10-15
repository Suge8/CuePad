import CueText
import SwiftUI

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
                    case .text(let text): Paragraphs(verbatim: text).font(Typography.body).foregroundStyle(palette.ink)
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

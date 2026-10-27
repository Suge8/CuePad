import CueText
import SwiftUI

/// 带上的卡片或任务的全文：文字、图片、文件按原来的顺序；标题已写在面板顶上，正文从标题之后开始。
/// `height` 报出内容的高度，面板按它定高。
struct AttachmentBody: View {
    let content: String
    @Binding var height: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = Self.blocks(content)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): Paragraphs(verbatim: text).font(Typography.body).foregroundStyle(palette.ink)
                    case .image(let hash): Thumbnail(hash: hash, height: 220, radius: 12)
                    case .file(let key, let name): FileChip(key: key, name: name).frame(maxWidth: 360)
                    }
                }
            }
            .padding(blocks.isEmpty ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .background(palette.paper, in: .rect)
    }

    /// 文字与附件按原顺序各成一块，删掉正文开头的标题那一行。
    private static func blocks(_ content: String) -> [CueToken] {
        var blocks = CueFormat.parse(content)
        if case .text(let first)? = blocks.first {
            let title = CueSummary.title(of: content)
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

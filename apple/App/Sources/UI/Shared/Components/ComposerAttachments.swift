import CueText
import SwiftUI

struct AttachmentBody: View {
    let content: String
    @Binding var height: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = Self.blocks(content), attached = blocks.compactMap(DraftFile.init)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text): Paragraphs(verbatim: text).font(Typography.body).foregroundStyle(palette.ink)
                    case .image(let hash): Thumbnail(hash: hash, height: 220, cornerRadius: Radius.block)
                    case .file(let key, let name): FileChip(key: key, name: name, among: attached, group: "card").frame(maxWidth: 360)
                    }
                }
            }
            .padding(blocks.isEmpty ? 0 : Spacing.panel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .background(palette.paper, in: .rect)
    }

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

import SwiftUI

struct InspirationPaper: View {
    /// 编辑与长图沿用同一列。
    static let textWidth: CGFloat = 680
    let source: String
    var images: [String: CGImage] = [:]
    @Environment(\.palette) private var palette

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block).padding(.bottom, gap(after: index, in: blocks))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(Typography.reading)
        .foregroundStyle(palette.ink)
        .lineSpacing(Typography.readingLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gap(after index: Int, in blocks: [MarkdownBlock]) -> CGFloat {
        guard index + 1 < blocks.count else { return 0 }
        if blocks[index].isList, blocks[index + 1].isList { return Spacing.item }
        return Spacing.part
    }

    private func blockView(_ block: MarkdownBlock) -> some View {
        MarkdownBlockFrame(block: block) { blockContent(block) }
    }

    @ViewBuilder private func blockContent(_ block: MarkdownBlock) -> some View {
        switch block.content {
        case .heading(let level, let text):
            MarkdownMediaView(source: text, images: images, exporting: true)
                .font(level == 1 ? Typography.heading : level == 2 ? Typography.readingHeading : Typography.reading.weight(.semibold))
                .padding(.top, Spacing.item)
        case .code(let code):
            Text(verbatim: code).font(Typography.code)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.group)
                .background(palette.fill, in: .rect(cornerRadius: Radius.block))
        case .quote(let text):
            HStack(alignment: .top, spacing: Spacing.group) {
                Rectangle().fill(palette.ink3).frame(width: 2)
                MarkdownMediaView(source: text, images: images, exporting: true).foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table, images: images, exporting: true)
        case .paragraph(let text):
            MarkdownMediaView(source: text, images: images, exporting: true).frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Rectangle().fill(palette.hair).frame(width: 44, height: 1).padding(.vertical, Spacing.item)
        }
    }
}

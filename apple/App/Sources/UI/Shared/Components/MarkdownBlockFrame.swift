import SwiftUI

struct MarkdownBlockFrame<Content: View>: View {
    let block: MarkdownBlock
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        if let item = block.list.last {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                Text(verbatim: item.marker).font(Typography.reading).foregroundStyle(palette.ink3)
                    .opacity(block.startsItem ? 1 : 0).readerHidden(!block.startsItem)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(block.depth) * Spacing.part)
        } else { content() }
    }
}

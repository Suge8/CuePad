import CueStore
import SwiftUI

/// 技能与规则页的一张卡：同灵感墙的卡一个样（`CardTitle`、`CardPreview`、`paper()`），标题前可带图标，脚注放谁读不到这类记号。
struct LibraryCard<Lead: View, Meta: View>: View {
    let title: String
    var dim = false
    let preview: String
    var lines = CardText.previewLines
    let open: () -> Void
    @ViewBuilder var lead: Lead
    @ViewBuilder var meta: Meta
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: CardFaceMetrics.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                    lead
                    CardTitle(text: title, dim: dim)
                }
                if !preview.isEmpty { CardPreview(text: preview, lines: lines) }
                meta.font(Typography.meta).foregroundStyle(palette.ink3)
            }
            .multilineTextAlignment(.leading)
            .padding(CardFaceMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper()
            .contentShape(.rect(cornerRadius: Radius.card))
        }
        .cardButton()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 按下同灵感墙的卡。
    func cardButton() -> some View {
        #if os(macOS)
        buttonStyle(CardOpenStyle())
        #else
        buttonStyle(PressStyle(.card))
        #endif
    }
}

/// 列宽、列数与间距同项目页的灵感墙。
struct LibraryWall<Content: View>: View {
    @ViewBuilder var content: Content
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    #endif

    var body: some View {
        #if os(macOS)
        MasonryLayout(minColumnWidth: 260, maxColumns: 12, spacing: Spacing.block) { content }
        #else
        MasonryLayout(minColumnWidth: sizeClass == .regular ? 220 : 150, maxColumns: typeSize.isAccessibilitySize ? 1 : 4, spacing: Spacing.group) { content }
        #endif
    }
}

import SwiftUI

/// 灵感墙上一张卡的面，三端同一份；手机窄屏的墙列窄，字与留白小一号。外面的按钮、悬停、轻扫、放大转场由各端的壳加。
struct IdeaTileFace: View {
    private static let dotTuck: CGFloat = 6
    let entry: CardEntry
    let floated: Bool
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var height = NoteTile.height
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var small: Bool { sizeClass == .compact }
    private static let previewLineSpacing: CGFloat = 0
    #else
    private let small = false
    private static let previewLineSpacing = Typography.lineSpacing
    #endif

    var body: some View {
        let card = entry.card, text = entry.text, image = text.images.first
        VStack(alignment: .leading, spacing: 0) {
            if let image { Thumbnail(hash: image, height: NoteTile.thumbnail, framed: false) }
            VStack(alignment: .leading, spacing: small ? Spacing.tight : Spacing.item) {
                HStack(alignment: .firstTextBaseline, spacing: small ? Spacing.tight : Spacing.glyph) {
                    Text(text.label)
                        .font(small ? Typography.secondaryBold : Typography.bodyStrong)
                        .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                        .lineLimit(image == nil ? NoteTile.titleLines : 1)
                    Spacer(minLength: 0)
                    AgentDot(card: card.id).padding(.vertical, small ? -AgentDot.overhang : 0).padding(.trailing, small ? -Self.dotTuck : 0)
                }
                if image == nil, !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette))
                        .font(small ? Typography.meta : Typography.body).lineSpacing(small ? 0 : Self.previewLineSpacing).foregroundStyle(palette.ink2)
                        .lineLimit(CardText.previewLines)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    Spacer(minLength: 0)
                }
                CardMeta(card: card, text: text, floated: floated, font: small ? Typography.caption2 : Typography.meta)
            }
            .multilineTextAlignment(.leading)
            .padding(small ? Spacing.group : Spacing.block)
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
        .clipShape(.rect(cornerRadius: Radius.card))
    }
}

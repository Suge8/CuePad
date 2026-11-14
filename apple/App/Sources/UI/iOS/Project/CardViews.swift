#if os(iOS)
import SwiftUI

struct CardTileView: View {
    /// 会话点（看得见的那颗，不是它 44 的点按格）往卡的右内边里收一截：点离卡右边与标题离左边看着一样。
    private static let dotTuck: CGFloat = 6
    let entry: CardEntry
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Route.card(card.id)) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 96, cornerRadius: Radius.block).padding(.bottom, Spacing.tight)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    Text(text.label)
                        .font(Typography.secondary.weight(.semibold))
                        .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    AgentDot(card: card.id).padding(.vertical, -AgentDot.overhang).padding(.trailing, -Self.dotTuck)
                }
                if !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette))
                        .font(Typography.meta).foregroundStyle(palette.ink2)
                        .lineLimit(text.images.isEmpty ? CardText.previewLines : 2)
                }
                CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated)
                    .padding(.top, Spacing.tight)
            }
            .multilineTextAlignment(.leading)
            .padding(Spacing.group)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper()
            .contentShape(.rect(cornerRadius: Radius.card))
        }
        .buttonStyle(PressStyle(.card))
        .zoomSource(card.id, in: zoom)
        .rowSwipes(.card(card, workspace: workspace), clipped: false)
        .contextMenu { CardActions(card: card) }
        .cardDraggable(.idea(card.id), shape: .rect(cornerRadius: Radius.card))
    }
}
#endif

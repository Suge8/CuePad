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

struct OlderGroupHeader: View {
    let group: OlderGroup
    @Binding var expanded: Set<OlderGroup.Period>
    @Environment(\.palette) private var palette

    var body: some View {
        let collapsible = group.isMonth
        let open = !collapsible || expanded.contains(group.period)
        Button {
            withAnimation(Motion.fade) {
                if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
            }
        } label: {
            HStack {
                if collapsible {
                    Chevron(.forward).rotationEffect(.degrees(open ? 90 : 0))
                }
                SectionHeader(Dotted(OlderGroupTitle.text(group.period)), level: .group)
                Spacer()
                if collapsible && !open { Text("\(group.cards.count) 条").font(Typography.caption).foregroundStyle(palette.ink3) }
            }
            .padding(.horizontal, Spacing.tight)
            .frame(minHeight: collapsible ? 44 : nil)
            .padding(.top, collapsible ? Spacing.tight : Spacing.group).padding(.bottom, collapsible ? 0 : Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
    }
}

struct OlderRow: View {
    let entry: CardEntry
    let lastTarget: String?
    let isFirst: Bool
    let isLast: Bool
    var pinned = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Radius.block : 0, bottomLeadingRadius: isLast ? Radius.block : 0,
            bottomTrailingRadius: isLast ? Radius.block : 0, topTrailingRadius: isFirst ? Radius.block : 0)
    }

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Route.card(card.id)) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                if pinned { Image(.pin).font(Typography.meta).foregroundStyle(palette.ink2).iconLabel("已置顶") }
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(text.label).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    // 只有标题的也占着第二行：同一张纸上的行一样高
                    Text(text.preview.isEmpty ? " " : text.preview).font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                AgentDot(card: card.id).padding(.vertical, -AgentDot.overhang)
                if let lastTarget { SentMark(target: lastTarget).font(Typography.caption2).foregroundStyle(palette.ink3) }
                if !text.attachments.isEmpty { AttachmentMark(count: text.attachments.count).font(Typography.caption2).foregroundStyle(palette.ink3) }
                Text(DateLabel.short(card.modifiedAt)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .background(palette.paper, in: .rect)
        .clipShape(shape)
        .rowContainer(shape, flush: true)
        .zoomSource(card.id, in: zoom)
        .rowSwipes(.card(card, workspace: workspace))
        .contextMenu { CardActions(card: card) }
        .cardDraggable(.idea(card.id), shape: shape)
    }
}

#endif

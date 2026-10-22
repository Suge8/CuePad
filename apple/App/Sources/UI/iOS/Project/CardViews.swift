#if os(iOS)
import SwiftUI

/// 墙上的一张灵感。点开用系统缩放过渡放大成纸页；轻扫同所有灵感（`CardMenu.swipes`）；交给过 Agent 时右上角是那个会话的状态点；长按是菜单。
struct CardTileView: View {
    let entry: CardEntry
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Route.card(card.id)) {
            // 标题与正文挨着读成一段，日期另起一小段
            VStack(alignment: .leading, spacing: 4) {
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 96, radius: 9).padding(.bottom, 4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(text.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    AgentDot(card: card.id).padding(.vertical, -8).padding(.trailing, -6)
                }
                if !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette))
                        .font(.footnote).foregroundStyle(palette.ink2)
                        .lineLimit(text.images.isEmpty ? CardText.previewLines : 2)
                }
                CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated)
                    .padding(.top, 6)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(PressStyle(.card))
        .zoomSource(card.id, in: zoom)
        .rowSwipes(.card(card, workspace: workspace), clipped: false)
        .contextMenu { CardActions(card: card) }
    }
}

/// "更早"的一组：标题行（按月的组可折叠，折叠时带张数）。
struct OlderGroupHeader: View {
    let group: OlderGroup
    @Binding var expanded: Set<OlderGroup.Period>
    @Environment(\.palette) private var palette

    var body: some View {
        let collapsible = group.isMonth
        let open = !collapsible || expanded.contains(group.period)
        Button {
            withAnimation(HandOff.quick) {
                if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
            }
        } label: {
            HStack {
                if collapsible {
                    Image(.forward).font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                }
                Text(OlderGroupTitle.text(group.period)).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                Spacer()
                if collapsible && !open { Text("\(group.cards.count) 条").font(.caption).foregroundStyle(palette.ink3) }
            }
            .padding(.horizontal, 4)
            // 能折起的月份要点得到；周标题只是标题，紧贴它下面那组
            .frame(minHeight: collapsible ? 44 : nil)
            .padding(.top, collapsible ? 4 : 12).padding(.bottom, collapsible ? 0 : 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
    }
}

/// "更早"里的一行。每行是懒加载列表里独立的一项：同组的行拼成一张纸（首尾圆角、行间分隔线），
/// 大项目几百张旧卡也只创建屏幕内的行。
struct OlderRow: View {
    let entry: CardEntry
    let lastTarget: String?
    let isFirst: Bool
    let isLast: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    private static let radius: CGFloat = 12

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Self.radius : 0, bottomLeadingRadius: isLast ? Self.radius : 0,
            bottomTrailingRadius: isLast ? Self.radius : 0, topTrailingRadius: isFirst ? Self.radius : 0, style: .continuous)
    }

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Route.card(card.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.label).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    if !text.preview.isEmpty {
                        Text(text.preview).font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                AgentDot(card: card.id).padding(.vertical, -8)
                if let lastTarget { SentMark(target: lastTarget).font(Typography.caption2).foregroundStyle(palette.ink3) }
                Text(DateLabel.short(card.modifiedAt)).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .background(palette.paper, in: .rect)
        .overlay(alignment: .top) { if !isFirst { Divider().padding(.leading, 14) } }
        // 一组行拼成一张纸：每行按它在组里的位置裁角，也是它的行容器
        .clipShape(shape)
        .rowContainer(shape, flush: true)
        .zoomSource(card.id, in: zoom)
        .rowSwipes(.card(card, workspace: workspace))
        .contextMenu { CardActions(card: card) }
    }
}

#endif

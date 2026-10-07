#if os(iOS)
import CueStore
import SwiftUI

/// 墙上的一张卡。点开用系统缩放过渡放大成纸页；向右轻扫是"要做"；长按是卡片操作。
struct CardTileView: View {
    let entry: CardEntry
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Navigation.Route.card(card.id)) {
            VStack(alignment: .leading, spacing: 6) {
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 96, radius: 9).padding(.bottom, 4)
                }
                Text(text.title.nonEmpty ?? "无标题")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(3)
                if !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette))
                        .font(.footnote).foregroundStyle(palette.ink2)
                        .lineLimit(text.images.isEmpty ? 5 : 2)
                }
                CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(CardPressStyle())
        .zoomSource(card.id, in: zoom)
        .rowSwipe(right: .todo(card.id, in: workspace))
        .contextMenu { CardActions(card: card) }
        .ideaDrag(card.id)
    }
}

extension SwipeAction {
    /// 灵感上向右轻扫：设为任务（提示里可撤销）。
    @MainActor static func todo(_ id: UUID, in workspace: Workspace) -> SwipeAction {
        SwipeAction(symbol: "checklist") { workspace.toggleTodo(id, true) }
    }
}

extension Workspace {
    /// 复制整张卡（变量已填），写一条发送记录。
    func copy(_ card: Card) {
        let text = Outgoing.text(of: card), id = card.id
        attempt {
            try await self.services.send(text, to: .clipboard, card: id)
            self.say("已复制")
        }
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
            withAnimation(Motion.quick) {
                if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
            }
        } label: {
            HStack {
                if collapsible {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                }
                Text(OlderGroupTitle.text(group.period)).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                Spacer()
                if collapsible && !open { Text("\(group.cards.count) 条").font(.caption).foregroundStyle(palette.ink3) }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
        .padding(.top, 8)
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

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Navigation.Route.card(card.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title.nonEmpty ?? "无标题").font(.subheadline.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    if !text.preview.isEmpty {
                        Text(text.preview).font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let lastTarget { Text("→ \(lastTarget)").font(.caption2).foregroundStyle(palette.ink3).lineLimit(1) }
                Text(DateLabel.short(card.modifiedAt)).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .background(palette.paper)
        .overlay(alignment: .top) { if !isFirst { Divider().padding(.leading, 14) } }
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Self.radius : 0, bottomLeadingRadius: isLast ? Self.radius : 0,
            bottomTrailingRadius: isLast ? Self.radius : 0, topTrailingRadius: isFirst ? Self.radius : 0, style: .continuous))
        .zoomSource(card.id, in: zoom)
        .rowSwipe(right: .todo(card.id, in: workspace))
        .contextMenu { CardActions(card: card) }
        .ideaDrag(card.id)
    }
}

#endif

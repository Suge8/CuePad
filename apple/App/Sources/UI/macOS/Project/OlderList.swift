#if os(macOS)
import CueStore
import SwiftUI

struct OlderList: View {
    let groups: [OlderGroup]
    let cards: [UUID: Card]
    let lastTarget: [UUID: String]
    @Environment(\.palette) private var palette
    @State private var expanded: Set<OlderGroup.Period> = []

    var body: some View {
        let total = groups.reduce(0) { $0 + $1.cards.count }
        VStack(alignment: .leading, spacing: Spacing.page) {
            SectionHeader("更早", count: total).id(ScrollAnchor.older)
            let titled = OlderGroup.needsTitles(in: groups)
            ForEach(groups, id: \.period) { group in
                section(group, titled: titled)
            }
        }
    }

    private func section(_ group: OlderGroup, titled: Bool) -> some View {
        let open = isExpanded(group)
        let header = HStack {
            if group.isMonth { Chevron(.forward).rotationEffect(.degrees(open ? 90 : 0)) }
            Text(OlderGroupTitle.text(group.period)).font(Typography.label).foregroundStyle(palette.ink2)
            Spacer()
            Text("\(group.cards.count) 条").font(Typography.meta).foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, Spacing.tight)
        .contentShape(.rect)
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            if group.isMonth {
                Button {
                    withAnimation(Motion.fade) {
                        if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
                    }
                } label: { header }
                .buttonStyle(PressStyle())
                .accessibilityValue(open ? "已展开" : "已折叠")
            } else if titled {
                header.accessibilityAddTraits(.isHeader)
            }
            if open {
                // 懒加载：大项目三个月内按周展开的行可达上千，全建出来时每个滚轮事件的命中测试与每帧布局都按行数增长。
                // 行高固定，未建出的部分高度估得准，滚动条不跳
                LazyVStack(spacing: 0) {
                    ForEach(group.cards.compactMap { cards[$0] }) { card in
                        OlderRow(card: card, lastTarget: lastTarget[card.id])
                    }
                }
                .rowPaper(cornerRadius: Radius.block)
            }
        }
    }

    private func isExpanded(_ group: OlderGroup) -> Bool {
        !group.isMonth || expanded.contains(group.period)
    }
}

struct OlderRow: View {
    let card: Card
    let lastTarget: String?
    var pinned = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button(action: open) { OlderRowLine(card: card, lastTarget: lastTarget, pinned: pinned) }
            .buttonStyle(CardOpenStyle())
            .cardPresence(card.id, in: workspace)
            .cardDraggable(.idea(card.id), shape: .rect(cornerRadius: Radius.row))
            .contextMenu { CardActions(card: card, selectable: true) }
            .accessibilityElement(children: .combine)
    }
}

/// 行的内容与底：选中读自卡片的批量选择（`cardSelected`，挂在按钮外面），所以在按钮里面单拆一层。
private struct OlderRowLine: View {
    let card: Card
    let lastTarget: String?
    let pinned: Bool
    @Environment(\.cardSelected) private var selected
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(card.body)
        HStack(spacing: Spacing.item) {
            RowGlyph(attached: !text.attachments.isEmpty, pinned: pinned)
            Text(text.label)
                .font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(text.preview).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            AgentDot(card: card.id)
            if let lastTarget { SentMark(target: lastTarget) }
            Text(DateLabel.short(card.modifiedAt)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, Spacing.inset).frame(height: 38)
        .contentShape(.rect)
        .hoverReveal(when: !workspace.presses.isSelecting) { DeleteCardButton(card: card.id).padding(.horizontal, Spacing.item) }
        .row(selected: selected)
    }
}

extension OlderRow {
    fileprivate func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

private struct RowGlyph: View {
    let attached: Bool
    let pinned: Bool
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if selected {
                PickedMark()
            } else {
                Image(pinned ? .pin : attached ? .attachment : .document).foregroundStyle(pinned ? palette.ink2 : palette.ink3)
            }
        }
        .font(Glyph.row).frame(width: 18)
        .accessibilityLabel(selected ? "已选" : pinned ? "置顶的灵感" : attached ? "含附件的灵感" : "灵感")
    }
}

#endif

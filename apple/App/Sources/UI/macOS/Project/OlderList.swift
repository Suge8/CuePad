#if os(macOS)
import CueStore
import SwiftUI

/// "更早"：墙以外的卡，三个月内按周分组（每周只有一条的月份并成一组），更久按月分组且默认折叠。点开的卡被编辑后回到墙首。
struct OlderList: View {
    let groups: [OlderGroup]
    let cards: [UUID: Card]
    let lastTarget: [UUID: String]
    @Environment(\.palette) private var palette
    @State private var expanded: Set<OlderGroup.Period> = []

    var body: some View {
        let total = groups.reduce(0) { $0 + $1.cards.count }
        VStack(alignment: .leading, spacing: 18) {
            // 与"资料""最近"同一种分组标题
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("更早").font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Text("\(total)").font(Typography.sectionCount).foregroundStyle(palette.ink3)
            }
            .id(ScrollAnchor.older)
            let titled = OlderGroup.needsTitles(in: groups)
            ForEach(groups, id: \.period) { group in
                section(group, titled: titled)
            }
        }
    }

    private func section(_ group: OlderGroup, titled: Bool) -> some View {
        let open = isExpanded(group)
        let header = HStack {
            if group.isMonth {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Text(OlderGroupTitle.text(group.period)).font(Typography.label).foregroundStyle(palette.ink2)
            Spacer()
            Text("\(group.cards.count) 条").font(Typography.meta).foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, 4)
        .contentShape(.rect)
        return VStack(alignment: .leading, spacing: 6) {
            if group.isMonth {
                Button {
                    withAnimation(Motion.quick) {
                        if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
                    }
                } label: { header }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "已展开" : "已折叠")
            } else if titled {
                header.accessibilityAddTraits(.isHeader)
            }
            if open {
                // 懒加载：大项目三个月内按周展开的行可达上千，全建出来时每个滚轮事件的命中测试与每帧布局都按行数增长。
                // 行高固定，未建出的部分高度估得准，滚动条不跳
                LazyVStack(spacing: 0) {
                    ForEach(Array(group.cards.compactMap { cards[$0] }.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { Rectangle().fill(palette.hair).frame(height: 1).padding(.leading, 40) }
                        OlderRow(card: card, lastTarget: lastTarget[card.id])
                    }
                }
                .paper(radius: 12)
            }
        }
    }

    /// 周分组常开；月分组默认折叠。
    private func isExpanded(_ group: OlderGroup) -> Bool {
        !group.isMonth || expanded.contains(group.period)
    }
}

struct OlderRow: View {
    let card: Card
    let lastTarget: String?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let text = CardText(card.body)
        Button(action: open) {
        HStack(spacing: 10) {
            RowGlyph(images: !text.images.isEmpty)
            Text(text.label)
                .font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(text.preview).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            AgentDot(card: card.id)
            if let lastTarget { SentMark(target: lastTarget) }
            if hovering, !workspace.presses.isSelecting { DeleteCardButton(card: card.id).transition(.opacity) }
            Text(DateLabel.short(card.modifiedAt)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, 12).frame(height: 38)
        .background(hovering ? palette.fill : .clear)
        .background { SelectedFill() }
        .contentShape(.rect)
        }
        .buttonStyle(CardOpenStyle())
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card, selectable: true) }
        .accessibilityElement(children: .combine)
    }
}

extension OlderRow {
    fileprivate func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

/// 行首的小图标；批量选择里选上时换成签名色的对勾。
private struct RowGlyph: View {
    let images: Bool
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.onSignature, palette.signature)
            } else {
                Image(systemName: images ? "photo" : "doc.text").foregroundStyle(palette.ink3)
            }
        }
        .font(.system(size: 13)).frame(width: 18)
        .accessibilityLabel(selected ? "已选" : images ? "含图片的灵感" : "灵感")
    }
}

/// 选上的行垫一层选中色。
private struct SelectedFill: View {
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        if selected { palette.selection }
    }
}
#endif

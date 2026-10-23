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
            // 与"最近"同一种分组标题
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
                Image(.forward).font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
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
                    withAnimation(HandOff.quick) {
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
                    ForEach(Array(group.cards.compactMap { cards[$0] }.enumerated()), id: \.element.id) { index, card in
                        if index > 0 { Rectangle().fill(palette.hair).frame(height: 1).padding(.leading, 40) }
                        OlderRow(card: card, lastTarget: lastTarget[card.id])
                    }
                }
                .rowPaper(radius: 12)
            }
        }
    }

    /// 周分组常开；月分组默认折叠。
    private func isExpanded(_ group: OlderGroup) -> Bool {
        !group.isMonth || expanded.contains(group.period)
    }
}

/// "更早"与置顶的灵感里的一行：点开编辑页；指针停着时铺行的淡底、行尾浮出删除（`hoverReveal`，批量选择时不出），批量选择里选上的是选中底（`RowStyle`）。
/// 置顶的（`pinned`）行首是图钉，那一组不另起组名。同墙上的卡，拖到任务纸的一行上接进那条任务。
struct OlderRow: View {
    let card: Card
    let lastTarget: String?
    var pinned = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button(action: open) { OlderRowLine(card: card, lastTarget: lastTarget, pinned: pinned) }
            .buttonStyle(CardOpenStyle())
            .cardPresence(card.id, in: workspace)
            .onDrag { CardDragSession.shared.begin(.idea(card.id)) }
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
        HStack(spacing: 10) {
            RowGlyph(images: !text.images.isEmpty, pinned: pinned)
            Text(text.label)
                .font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(text.preview).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            AgentDot(card: card.id)
            if let lastTarget { SentMark(target: lastTarget) }
            Text(DateLabel.short(card.modifiedAt)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
        .font(Typography.meta).foregroundStyle(palette.ink3)
        .padding(.horizontal, 12).frame(height: 38)
        .contentShape(.rect)
        .hoverReveal(when: !workspace.presses.isSelecting) { DeleteCardButton(card: card.id).padding(.horizontal, 8) }
        .row(selected: selected)
    }
}

extension OlderRow {
    fileprivate func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

/// 行首的小图标（置顶的是图钉）；批量选择里选上时换成签名色的对勾。
private struct RowGlyph: View {
    let images: Bool
    let pinned: Bool
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if selected {
                Image(.picked).foregroundStyle(palette.onFill, palette.signature)
            } else {
                Image(pinned ? .pin : images ? .photo : .document).foregroundStyle(pinned ? palette.ink2 : palette.ink3)
            }
        }
        .font(.system(size: 13)).frame(width: 18)
        .accessibilityLabel(selected ? "已选" : pinned ? "置顶的灵感" : images ? "含图片的灵感" : "灵感")
    }
}

#endif

#if os(macOS)
import CueStore
import SwiftUI

/// "更早"：墙以外的卡，三个月内按周分组，更久按月分组且默认折叠。点开的卡被编辑后回到墙首。
struct OlderList: View {
    let groups: [OlderGroup]
    let cards: [UUID: Card]
    let lastTarget: [UUID: String]
    @Environment(\.palette) private var palette
    @State private var expanded: Set<OlderGroup.Period> = []

    var body: some View {
        let total = groups.reduce(0) { $0 + $1.cards.count }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                PaperStack()
                HStack(alignment: .bottom, spacing: 6) {
                    Text("更早").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
                    Text("\(total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(palette.ink3)
                }
                Rectangle().fill(palette.hair).frame(height: 1)
            }
            .padding(.top, 8)
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
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Text(OlderGroupTitle.text(group.period)).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink2)
            Spacer()
            Text("\(group.cards.count) 条").font(.system(size: 11)).foregroundStyle(palette.ink3)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let text = CardText(card.body)
        Button(action: open) {
        HStack(spacing: 10) {
            Image(systemName: !text.images.isEmpty ? "photo" : "doc.text")
                .font(.system(size: 12)).foregroundStyle(palette.ink3).frame(width: 18)
                .accessibilityLabel(text.images.isEmpty ? "灵感" : "含图片的灵感")
            Text(text.title.isEmpty ? "无标题" : text.title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(text.preview).font(.system(size: 13)).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            if let lastTarget { SentMark(target: lastTarget) }
            Text(DateLabel.short(card.modifiedAt)).monospacedDigit().frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 11.5)).foregroundStyle(palette.ink3)
        .padding(.horizontal, 12).frame(height: 34)
        .background(hovering ? palette.fill : .clear)
        .contentShape(.rect)
        }
        .buttonStyle(CardOpenStyle())
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card) }
        .ideaDrag(card.id)
        .accessibilityElement(children: .combine)
    }
}

extension OlderRow {
    fileprivate func open() {
        workspace.openCard = card.id
    }
}

/// 三张错位的纸边：墙上的卡片"压"成列表的过渡记号。
private struct PaperStack: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 4).fill(palette.paper)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.ink3.opacity(0.5), lineWidth: 1))
                    .frame(width: 22, height: 16)
                    .offset(x: CGFloat(index) * 3, y: CGFloat(-index) * 3)
            }
        }
        .frame(width: 30, height: 26)
        .accessibilityHidden(true)
    }
}
#endif

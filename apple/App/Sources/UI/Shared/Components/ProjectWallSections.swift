import CueStore
import SwiftUI

/// 项目页任务纸下面的几段（两端同一份编排）：已置顶、"最近"墙、"更早"按时间分组（月份的组可折叠，开合放在这里）。
/// 页只管滚动、栏头与分帧建；卡片墙的格（`tile`）各端自己画。`entry` 按需取：大项目的"更早"可达上千行，只取建出来的那几行。
struct ProjectWallSections<Tile: View>: View {
    let data: ProjectPageData
    let arrangement: WallArrangement
    let older: [OlderGroup]
    let entry: (UUID) -> CardEntry?
    let metrics: Metrics
    /// Mac 首次挂上时"更早"晚一帧建（`ProjectPage.Stage`）。
    var showsOlder = true
    @ViewBuilder let tile: (CardEntry) -> Tile
    @State private var expanded: Set<OlderGroup.Period> = []

    struct Metrics {
        let minColumnWidth: CGFloat
        let maxColumns: Int
        let wallSpacing: CGFloat
        let sectionGap: CGFloat
        /// 段名（"最近""更早"）到它下面那块。
        let headerGap: CGFloat
        /// "更早"没有分组标题时，段名到那一张纸。
        let olderGap: CGFloat
    }

    var body: some View {
        let lastTarget = data.lastTarget
        LazyVStack(alignment: .leading, spacing: 0) {
            if data.cards.isEmpty {
                wall { EmptyWallTile() }
            }
            if !arrangement.pinned.isEmpty {
                rows(arrangement.pinned, lastTarget: lastTarget, pinned: true).padding(.bottom, metrics.sectionGap)
            }
            if !arrangement.wall.isEmpty {
                SectionHeader("最近", count: arrangement.wall.count).padding(.bottom, metrics.headerGap)
                wall {
                    ForEach(arrangement.wall.compactMap(entry)) { tile($0).transition(.opacity) }
                }
                .padding(.bottom, metrics.sectionGap)
            }
            if showsOlder, !older.isEmpty {
                let titled = OlderGroup.needsTitles(in: older)
                SectionHeader("更早", count: arrangement.older.count).id(ScrollAnchor.older).padding(.bottom, titled ? 0 : metrics.olderGap)
                ForEach(older, id: \.period) { group in
                    if titled { OlderGroupHeader(group: group, expanded: $expanded) }
                    if !group.isMonth || expanded.contains(group.period) { rows(group.cards, lastTarget: lastTarget) }
                }
            }
        }
    }

    private func wall(@ViewBuilder _ tiles: () -> some View) -> some View {
        MasonryLayout(minColumnWidth: metrics.minColumnWidth, maxColumns: metrics.maxColumns, spacing: metrics.wallSpacing) { tiles() }
    }

    /// 同一组的行在一张纸上：Mac 整组一张纸（悬停、多选的底在纸里），手机每行自带纸的那一截圆角（左滑的按钮要按行裁）。
    @ViewBuilder private func rows(_ ids: [UUID], lastTarget: [UUID: String], pinned: Bool = false) -> some View {
        #if os(macOS)
        LazyVStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if let entry = entry(id) { OlderRow(entry: entry, lastTarget: lastTarget[id], pinned: pinned) }
            }
        }
        .rowPaper(cornerRadius: Radius.block)
        #else
        ForEach(ids, id: \.self) { id in
            if let entry = entry(id) {
                OlderRow(entry: entry, lastTarget: lastTarget[id], pinned: pinned, isFirst: id == ids.first, isLast: id == ids.last)
            }
        }
        #endif
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
                if collapsible { Chevron(.forward).rotationEffect(.degrees(open ? 90 : 0)) }
                #if os(macOS)
                Text(OlderGroupTitle.text(group.period)).font(Typography.label).foregroundStyle(palette.ink2)
                Spacer()
                Text("\(group.cards.count) 条").font(Typography.meta).foregroundStyle(palette.ink3)
                #else
                SectionHeader(Dotted(OlderGroupTitle.text(group.period)), level: .group)
                Spacer()
                if collapsible && !open { Text("\(group.cards.count) 条").font(Typography.caption).foregroundStyle(palette.ink3) }
                #endif
            }
            .padding(.horizontal, Spacing.tight)
            #if os(macOS)
            .padding(.top, Spacing.page).padding(.bottom, Spacing.tight)
            #else
            .frame(minHeight: collapsible ? 44 : nil)
            .padding(.top, collapsible ? Spacing.tight : Spacing.group).padding(.bottom, collapsible ? 0 : Spacing.tight)
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .disabled(!collapsible)
        .accessibilityAddTraits(collapsible ? [] : .isHeader)
        .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
    }
}

/// 不在墙上的旧灵感（已置顶、"更早"）一行。Mac 一行字、悬停出删除、可多选；手机两行字、左滑出操作、点开放大成编辑页。
struct OlderRow: View {
    let entry: CardEntry
    let lastTarget: String?
    var pinned = false
    #if os(iOS)
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.zoomNamespace) private var zoom
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    #if os(macOS)
    var body: some View {
        let card = entry.card
        Button {
            guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
            workspace.open(card)
        } label: {
            OlderRowLine(entry: entry, lastTarget: lastTarget, pinned: pinned)
        }
        .buttonStyle(CardOpenStyle())
        .cardPresence(card.id, in: workspace)
        .cardDraggable(.idea(card.id), shape: .rect(cornerRadius: Radius.row))
        .contextMenu { CardActions(card: card, selectable: true) }
        .accessibilityElement(children: .combine)
    }
    #else
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
    #endif
}

#if os(macOS)
/// 行的内容与底：选中读自卡片的批量选择（`cardSelected`，挂在按钮外面），所以在按钮里面单拆一层。
private struct OlderRowLine: View {
    let entry: CardEntry
    let lastTarget: String?
    let pinned: Bool
    @Environment(\.cardSelected) private var selected
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let card = entry.card, text = entry.text
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

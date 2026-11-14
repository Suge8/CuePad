import CueStore
import SwiftUI

/// 项目页任务纸下面的几段（两端同一份编排）：已置顶、"最近"墙、"更早"按时间分组（月份的组可折叠，开合放在这里）。
/// 页只管滚动、栏头与分帧建；卡片墙的格（`tile`）各端自己画。
struct ProjectWallSections<Tile: View>: View {
    let data: ProjectPageData
    let arrangement: WallArrangement
    let older: [OlderGroup]
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
                    ForEach(arrangement.wall.compactMap { data.entries[$0] }) { tile($0).transition(.opacity) }
                }
                .padding(.bottom, metrics.sectionGap)
            }
            if showsOlder, !older.isEmpty {
                let titled = OlderGroup.needsTitles(in: older)
                SectionHeader("更早", count: arrangement.older.count).id(OlderGroup.anchor).padding(.bottom, titled ? 0 : metrics.olderGap)
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

    /// 同一组的行在一张纸上：Mac 整组一张纸（悬停、多选的底在纸里），手机每行自带纸的那一截圆角（左滑的按钮要按行裁，`OlderRow`）。
    private func rows(_ ids: [UUID], lastTarget: [UUID: String], pinned: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if let entry = data.entries[id] {
                    OlderRow(entry: entry, lastTarget: lastTarget[id], pinned: pinned, isFirst: id == ids.first, isLast: id == ids.last)
                }
            }
        }
        #if os(macOS)
        .rowPaper(cornerRadius: Radius.block)
        #endif
    }
}

extension WallBoard {
    /// 读到新数据、换了一天时整理墙（两端同一份）：头一次排不带动画；之后分区真变了才带（卡在墙与"更早"之间挪位）。
    static func rearrange(_ board: Binding<WallBoard>, with data: ProjectPageData, project: UUID, reduceMotion: Bool) {
        var next = board.wrappedValue
        if next.refresh(with: data, project: project) {
            board.wrappedValue = next
        } else if next != board.wrappedValue {
            withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { board.wrappedValue = next }
        }
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
    let pinned: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let card = entry.card
        let shape = shape
        OlderRowLine(entry: entry, lastTarget: lastTarget, pinned: pinned)
            .modifier(OlderRowOpens(card: card, shape: shape))
            .contextMenu { CardActions(card: card, selectable: Self.selectable) }
            .cardDraggable(.idea(card.id), shape: shape)
    }

    private var shape: UnevenRoundedRectangle {
        #if os(macOS)
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: Radius.row, bottomLeading: Radius.row, bottomTrailing: Radius.row, topTrailing: Radius.row))
        #else
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? Radius.block : 0, bottomLeadingRadius: isLast ? Radius.block : 0,
            bottomTrailingRadius: isLast ? Radius.block : 0, topTrailingRadius: isFirst ? Radius.block : 0)
        #endif
    }

    #if os(macOS)
    private static let selectable = true
    #else
    private static let selectable = false
    #endif
}

/// 点开：Mac 是按钮（⌘ 点、多选中点是选，`CardPresses`），手机是推入编辑页（从这一行放大）、左滑出操作。
private struct OlderRowOpens: ViewModifier {
    let card: Card
    let shape: UnevenRoundedRectangle
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.palette) private var palette
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        Button {
            guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
            workspace.open(card)
        } label: { content }
            .buttonStyle(CardOpenStyle())
            .cardPresence(card.id, in: workspace)
            .accessibilityElement(children: .combine)
        #else
        NavigationLink(value: Route.card(card.id)) { content }
            .buttonStyle(.row)
            .background(palette.paper, in: .rect)
            .clipShape(shape)
            .rowContainer(shape, flush: true)
            .zoomSource(card.id, in: zoom)
            .rowSwipes(.card(card, workspace: workspace))
        #endif
    }
}

/// 两端只差在字号、标题与预览横排还是叠成两行、类型图标在行首还是只标附件数（`Look`）与行的底（`OlderRowSurface`）。
private struct OlderRowLine: View {
    let entry: CardEntry
    let lastTarget: String?
    let pinned: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let card = entry.card, text = entry.text, attached = !text.attachments.isEmpty
        HStack(alignment: Look.alignment, spacing: Spacing.item) {
            if pinned || Look.typeGlyph { RowGlyph(attached: attached, pinned: pinned) }
            Look.titles {
                Text(text.label).font(Look.label).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
                // 叠成两行时只有标题的也占着第二行：同一张纸上的行一样高
                Text(text.preview.isEmpty ? " " : text.preview).font(Look.preview).foregroundStyle(palette.ink3).lineLimit(1)
            }
            Spacer(minLength: Look.gap)
            AgentDot(card: card.id).padding(.vertical, Look.dotInset)
            Group {
                if let lastTarget { SentMark(target: lastTarget) }
                if attached, !Look.typeGlyph { AttachmentMark(count: text.attachments.count) }
            }
            .font(Look.marks)
            Text(DateLabel.short(card.modifiedAt)).font(Look.date.monospacedDigit()).frame(minWidth: Look.dateWidth, alignment: .trailing)
        }
        .font(Look.base).foregroundStyle(palette.ink3)
        .modifier(OlderRowSurface(card: card.id))
    }

    private enum Look {
        #if os(macOS)
        static let base: Font? = Typography.meta
        static let alignment = VerticalAlignment.center
        static let titles = AnyLayout(HStackLayout(spacing: Spacing.item))
        static let typeGlyph = true
        static let label = Typography.body.weight(.medium)
        static let preview = Typography.secondary
        static let marks = Typography.meta
        static let date = Typography.meta
        static let dateWidth: CGFloat = 64
        static let gap: CGFloat = 12
        static let dotInset: CGFloat = 0
        #else
        static let base: Font? = nil
        static let alignment = VerticalAlignment.firstTextBaseline
        static let titles = AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.hair))
        static let typeGlyph = false
        static let label = Typography.secondary.weight(.medium)
        static let preview = Typography.meta
        static let marks = Typography.caption2
        static let date = Typography.caption
        static let dateWidth: CGFloat = 0
        static let gap: CGFloat = 8
        static let dotInset = -AgentDot.overhang
        #endif
    }
}

/// 行的底：Mac 一行定高、悬停出删除、选中读自卡片的批量选择（`cardSelected`，挂在按钮外面，所以在按钮里面这一层读）；手机只留边距。
private struct OlderRowSurface: ViewModifier {
    let card: UUID
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardSelected) private var selected
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(.horizontal, Spacing.inset).frame(height: 38)
            .contentShape(.rect)
            .hoverReveal(when: !workspace.presses.isSelecting) { DeleteCardButton(card: card).padding(.horizontal, Spacing.item) }
            .row(selected: selected)
        #else
        content
            .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
            .contentShape(.rect)
        #endif
    }
}

/// Mac 行首是类型（置顶、带附件、灵感，多选时是选中）；手机只在置顶时有。
private struct RowGlyph: View {
    let attached: Bool
    let pinned: Bool
    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(\.cardSelected) private var selected
    #else
    private let selected = false
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            if selected { PickedMark() } else { glyph }
            #else
            glyph
            #endif
        }
        .font(Glyph.row).frame(width: 18)
        .accessibilityLabel(selected ? "已选" : pinned ? "置顶的灵感" : attached ? "含附件的灵感" : "灵感")
    }

    private var glyph: some View {
        Image(pinned ? .pin : attached ? .attachment : .document).foregroundStyle(pinned ? palette.ink2 : palette.ink3)
    }
}

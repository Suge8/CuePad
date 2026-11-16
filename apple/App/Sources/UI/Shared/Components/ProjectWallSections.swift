import CueStore
import SwiftUI

/// 项目页任务区下面的几段（两端同一份编排）：灵感墙——第一格永远是"添加灵感"，接着是置顶的与最近的——和"更早"按时间分组的行（月份的组可折叠，开合放在这里）。
/// 页只管滚动、栏头与分帧建；卡片墙的格（`tile`）各端自己画。墙上不写段名：虚线那一格已经说了这是灵感。
struct ProjectWallSections<Tile: View>: View {
    let data: ProjectPageData
    let arrangement: WallArrangement
    let older: [OlderGroup]
    let metrics: Metrics
    /// Mac 首次挂上时"更早"晚一帧建（`ProjectPage.Stage`）。
    var showsOlder = true
    @ViewBuilder let tile: (CardEntry) -> Tile
    @State private var expanded: Set<OlderGroup.Period> = []
    /// 刚点"添加灵感"建出来、还没打开的那一条：等它落到墙上（读库的那一圈回来）再打开。
    @State private var born: Card?
    @Environment(Workspace.self) private var workspace
    #if os(macOS)
    @Environment(AppServices.self) private var services
    #endif

    struct Metrics {
        let minColumnWidth: CGFloat
        let maxColumns: Int
        let wallSpacing: CGFloat
        let sectionGap: CGFloat
        /// "更早"没有分组标题时，段名到那一组行。
        let olderGap: CGFloat
    }

    /// 新卡迟迟没落到这面墙上（项目刚被删、它落进了默认项目）时等这么久就照常打开。
    private static var landingWait: Duration { .milliseconds(400) }

    var body: some View {
        let lastTarget = data.lastTarget
        LazyVStack(alignment: .leading, spacing: 0) {
            MasonryLayout(minColumnWidth: metrics.minColumnWidth, maxColumns: metrics.maxColumns, spacing: metrics.wallSpacing) {
                AddIdeaTile(action: add)
                ForEach((arrangement.pinned + arrangement.wall).compactMap { data.entries[$0] }) { tile($0).transition(.opacity) }
            }
            .environment(\.noteColor, data.project?.color ?? Palette.neutralProject)
            .padding(.bottom, metrics.sectionGap)
            #if os(macOS)
            // 新装的 Mac 上灵感一条条地到：这一轮同步已久时说一声，空着的墙不读作"没有"
            if data.cards.isEmpty, services.syncing.showsCatchingUp {
                SyncingLabel().font(Typography.secondary).padding(.bottom, metrics.sectionGap)
            }
            #endif
            if showsOlder, !older.isEmpty {
                let titled = OlderGroup.needsTitles(in: older)
                SectionHeader("更早", count: arrangement.older.count).id(OlderGroup.anchor).padding(.bottom, titled ? 0 : metrics.olderGap)
                ForEach(older, id: \.period) { group in
                    if titled { OlderGroupHeader(group: group, expanded: $expanded) }
                    if !group.isMonth || expanded.contains(group.period) { rows(group.cards, lastTarget: lastTarget) }
                }
            }
        }
        .onChange(of: born.map { data.entries[$0.id] != nil } ?? false) { _, landed in
            guard landed, let card = born else { return }
            // 新卡那一格排好位置再打开：编辑页从它长出来
            Task {
                await NextFrame.wait()
                open(card)
            }
        }
    }

    private func add() {
        guard born == nil else { return }
        let project = data.project?.id ?? Project.defaultID
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            born = card
            try await Task.sleep(for: Self.landingWait)
            open(card)
        }
    }

    private func open(_ card: Card) {
        guard born?.id == card.id else { return }
        born = nil
        workspace.open(card)
    }

    /// 行直接落在桌面上，不装在纸里。手机的行自己留了左右的边（按下的底、左滑的按钮按行裁），整组向两边让出这一截，字与页边对齐。
    private func rows(_ ids: [UUID], lastTarget: [UUID: String]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if let entry = data.entries[id] { OlderRow(entry: entry, lastTarget: lastTarget[id]) }
            }
        }
        #if os(iOS)
        .padding(.horizontal, -OlderRow.inset)
        #endif
        .frame(maxWidth: Spacing.reading, alignment: .leading)
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
                Text(group.period.title()).font(Typography.label).foregroundStyle(palette.ink2)
                Spacer()
                Text("\(group.cards.count) 条").font(Typography.meta).foregroundStyle(palette.ink3)
                #else
                SectionHeader(Dotted(group.period.title()), level: .group)
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
        .frame(maxWidth: Spacing.reading, alignment: .leading)
        .disabled(!collapsible)
        .accessibilityAddTraits(collapsible ? [] : .isHeader)
        .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
    }
}

/// 不在墙上的旧灵感（"更早"）一行。Mac 一行字、悬停出删除、可多选；手机两行字、左滑出操作、点开放大成编辑页。
struct OlderRow: View {
    let entry: CardEntry
    let lastTarget: String?

    var body: some View {
        let card = entry.card
        let shape = RoundedRectangle(cornerRadius: Radius.row)
        OlderRowLine(entry: entry, lastTarget: lastTarget)
            .modifier(OlderRowOpens(card: card, shape: shape))
            .contextMenu { CardActions(card: card, selectable: Self.selectable) }
            .cardDraggable(.idea(card.id), shape: shape)
    }

    #if os(macOS)
    private static let selectable = true
    #else
    private static let selectable = false
    /// 手机的行里字离行的左右边。
    static let inset = Spacing.group
    #endif
}

/// 点开：Mac 是按钮（⌘ 点、多选中点是选，`CardPresses`），手机是推入编辑页（从这一行放大）、左滑出操作。
private struct OlderRowOpens: ViewModifier {
    let card: Card
    let shape: RoundedRectangle
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(\.zoomNamespace) private var zoom
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
    @Environment(\.palette) private var palette

    var body: some View {
        let card = entry.card, text = entry.text, attached = !text.attachments.isEmpty
        HStack(alignment: Look.alignment, spacing: Spacing.item) {
            #if os(macOS)
            RowGlyph(attached: attached)
            #endif
            Look.titles {
                Text(text.label).font(Look.label).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
                // 叠成两行时只有标题的也占着第二行：同一张纸上的行一样高
                Text(text.preview.isEmpty ? " " : text.preview).font(Look.preview).foregroundStyle(palette.ink3).lineLimit(1)
            }
            Spacer(minLength: Look.gap)
            AgentDot(card: card.id).padding(.vertical, Look.dotInset)
            Group {
                if let lastTarget { SentMark(target: lastTarget) }
                #if os(iOS)
                if attached { AttachmentMark(count: text.attachments.count) }
                #endif
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
        static let label = Typography.body.weight(.medium)
        static let preview = Typography.secondary
        static let marks = Typography.meta
        static let date = Typography.meta
        static let dateWidth: CGFloat = 64
        static let gap = Spacing.group
        static let dotInset: CGFloat = 0
        #else
        static let base: Font? = nil
        static let alignment = VerticalAlignment.firstTextBaseline
        static let titles = AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.hair))
        static let label = Typography.secondary.weight(.medium)
        static let preview = Typography.meta
        static let marks = Typography.caption2
        static let date = Typography.caption
        static let dateWidth: CGFloat = 0
        static let gap = Spacing.item
        static let dotInset = -AgentDot.overhang
        #endif
    }
}

/// 行的底：Mac 一行定高、悬停出删除、选中读自卡片的批量选择（`cardSelected`，挂在按钮外面，所以在按钮里面这一层读），字与页边对齐、底向两边让出去；手机只留边距。
private struct OlderRowSurface: ViewModifier {
    let card: UUID
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardSelected) private var selected
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .frame(height: 38)
            .contentShape(.rect)
            .hoverReveal(when: !workspace.presses.isSelecting) { DeleteCardButton(card: card).padding(.horizontal, Spacing.item) }
            .row(selected: selected)
        #else
        content
            .padding(.horizontal, OlderRow.inset).padding(.vertical, Spacing.item)
            .contentShape(.rect)
        #endif
    }
}

#if os(macOS)
/// 行首是类型（带附件、灵感），多选时是选中。
private struct RowGlyph: View {
    let attached: Bool
    @Environment(\.palette) private var palette
    @Environment(\.cardSelected) private var selected

    var body: some View {
        Group {
            if selected { PickedMark() } else { Image(attached ? .attachment : .document).foregroundStyle(palette.ink3) }
        }
        .font(Glyph.row).frame(width: 18)
        .accessibilityLabel(selected ? "已选" : attached ? "含附件的灵感" : "灵感")
    }
}
#endif

/// 位置只由顺序与宽度推出，不记"哪张在哪列"：墙上的顺序本身是稳定的（`WallArrangement`：同一次打开里编辑过的卡原地不动），记分列的话删卡、改成任务留下的空列会一直空着。
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var maxColumns = 4
    var spacing = Spacing.block

    private static let idealWidth: CGFloat = 900

    /// 同一轮排版里 SwiftUI 先量（`sizeThatFits`）再摆（`placeSubviews`），每张卡只量一遍。
    final class Memo {
        var width: CGFloat?
        var frames: [CGRect] = []
    }

    func makeCache(subviews: Subviews) -> Memo { Memo() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGSize {
        let width = fit(proposal.width).width
        return CGSize(width: width, height: frames(subviews, width: width, memo: cache).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width, memo: cache)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// 墙没有文字基线可对齐；默认实现会逐个询问子视图，侧栏开合时每帧都付这笔账（时间分析里约 4%）。
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }

    /// 墙没有固有宽度：问理想尺寸（nil）或最大尺寸（无穷）时按 `idealWidth` 排——无穷宽换算列数会让整数转换崩溃。
    private func fit(_ proposed: CGFloat?) -> (width: CGFloat, count: Int) {
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? Self.idealWidth
        return (width, max(1, min(maxColumns, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down)))))
    }

    private func frames(_ subviews: Subviews, width: CGFloat, memo: Memo) -> [CGRect] {
        if memo.width == width { return memo.frames }
        let count = fit(width).count
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var heights = Array(repeating: CGFloat(0), count: count)
        let frames = subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
        memo.width = width
        memo.frames = frames
        return frames
    }
}

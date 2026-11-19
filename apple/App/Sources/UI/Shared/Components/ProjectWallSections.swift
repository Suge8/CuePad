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
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    /// 刚点"添加灵感"建出来的那一条：它落到墙上之前，编辑页的放大从虚线那一格出发、空着返回也收回这一格（空白的不留，`dropIfBlank`）。
    @State private var born: UUID?
    @Environment(\.zoomNamespace) private var zoom
    #endif
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

    var body: some View {
        #if os(iOS)
        let held = born
        #else
        let held = UUID?.none
        #endif
        let shown = (arrangement.pinned + arrangement.wall).filter { data.entries[$0] != nil && $0 != held }
        LazyVStack(alignment: .leading, spacing: 0) {
            MasonryLayout(minColumnWidth: metrics.minColumnWidth, maxColumns: metrics.maxColumns, spacing: metrics.wallSpacing) {
                AddIdea(data: data, action: add)
                    #if os(iOS)
                    // 平时登记在一个不会有卡用的 id 上：这一格的身份不随登记换
                    .zoomSource(born ?? Project.defaultID, in: zoom)
                    #endif
                // 一张卡是一整块挪过去的（`geometryGroup`）：不然卡的底在滑，里面的字已经按新的宽排好、先到了，看着像字从卡上掉下来
                ForEach(shown.compactMap { data.entries[$0] }) { tile($0).geometryGroup().transition(.opacity) }
            }
            // 加一张、删一张，其余的卡滑到新位置，不是整面墙闪一下换好
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: shown)
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
                    if !group.isMonth || expanded.contains(group.period) { rows(group.cards) }
                }
            }
        }
    }

    #if os(iOS)
    /// 系统放大转场走完（约半秒）再留一点余量。
    private static var zoomSettle: Duration { .milliseconds(700) }
    #endif

    /// 建好就开，不等新卡落到墙上：等读库那一圈回来要停一拍。
    private func add() {
        guard !adding else { return }
        adding = true
        let project = data.project?.id ?? Project.defaultID
        workspace.attempt {
            defer { adding = false }
            let card = try await workspace.createCard(in: project)
            #if os(iOS)
            born = card.id
            // 虚线那一格先登记成这张卡的放大起点
            await NextFrame.wait()
            #endif
            workspace.open(card)
            #if os(iOS)
            // 放大的这一段新卡先不上墙：它一落下别的卡就让位、起点跟着换到它身上，看着是抖两下。盖严了再落，返回时缩回它那一格
            try? await Task.sleep(for: Self.zoomSettle)
            born = nil
            #endif
        }
    }

    /// 行直接落在桌面上，不装在纸里。手机的行自己留了左右的边（按下的底、左滑的按钮按行裁），整组向两边让出这一截，字与页边对齐。
    private func rows(_ ids: [UUID]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if let entry = data.entries[id] { OlderRow(entry: entry) }
            }
        }
        #if os(iOS)
        .padding(.horizontal, -OlderRow.inset)
        #endif
        .frame(maxWidth: Spacing.reading, alignment: .leading)
    }
}

/// 单独一个视图：只有它读会话状态，会话一动不重算整面墙。
private struct AddIdea: View {
    let data: ProjectPageData
    let action: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    var body: some View { AddIdeaTile(mood: mood, action: action) }

    private var mood: AddIdeaTile.Mood {
        let waits = data.tasks.ordered.contains { workspace.agent(of: $0.id, in: agents)?.shown.needsYou ?? false }
        if waits { return .waiting }
        return data.taskCounts.done > 0 && data.taskCounts.open == 0 ? .done : .idea
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

    var body: some View {
        let card = entry.card
        let shape = RoundedRectangle(cornerRadius: Radius.row)
        OlderRowLine(entry: entry)
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

import CueStore
import SwiftUI

struct ProjectWallSections: View {
    let data: ProjectPageData
    let board: WallBoard
    var showsOlder = true
    @State private var olderOpen = true
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @State private var born: UUID?
    @Environment(\.zoomNamespace) private var zoom
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(Workspace.self) private var workspace
    #if os(macOS)
    @Environment(AppServices.self) private var services
    #endif

    private struct Metrics {
        let minColumnWidth: CGFloat
        let maxColumns: Int
        let wallSpacing: CGFloat
        let olderGap: CGFloat
    }

    private var metrics: Metrics {
        let columns = typeSize.isAccessibilitySize ? 1 : nil
        #if os(iOS)
        if sizeClass == .compact { return Metrics(minColumnWidth: 150, maxColumns: columns ?? 4, wallSpacing: Spacing.group, olderGap: Spacing.item) }
        #endif
        return Metrics(minColumnWidth: 208, maxColumns: columns ?? 12, wallSpacing: Spacing.block, olderGap: Spacing.group)
    }

    var body: some View {
        if let arrangement = board.arrangement { wall(arrangement) }
    }

    private func wall(_ arrangement: WallArrangement) -> some View {
        #if os(iOS)
        let held = born
        #else
        let held = UUID?.none
        #endif
        let older = board.older
        let shown = (arrangement.pinned + arrangement.wall).filter { data.entries[$0] != nil && $0 != held }
        return LazyVStack(alignment: .leading, spacing: 0) {
            MasonryLayout(minColumnWidth: metrics.minColumnWidth, maxColumns: metrics.maxColumns, spacing: metrics.wallSpacing) {
                AddIdea(data: data, action: add)
                    #if os(iOS)
                    .zoomSource(born ?? Project.defaultID, in: zoom)
                    #endif
                // 一张卡是一整块挪过去的（`geometryGroup`）：不然卡的底在滑，里面的字已经按新的宽排好、先到了，看着像字从卡上掉下来
                ForEach(shown.compactMap { data.entries[$0] }) { IdeaTile(entry: $0, floated: board.floated.contains($0.id)).geometryGroup().transition(.opacity) }
            }
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: shown)
            .padding(.bottom, Spacing.section)
            #if os(macOS)
            if data.cards.isEmpty, services.syncing.showsCatchingUp {
                SyncingLabel().font(Typography.secondary).padding(.bottom, Spacing.section)
            }
            #endif
            if showsOlder, !older.isEmpty {
                let titled = OlderGroup.needsTitles(in: older)
                Button { withAnimation(Motion.fade) { olderOpen.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        SectionHeader("更早", count: arrangement.older.count)
                        Chevron(.forward).rotationEffect(.degrees(olderOpen ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(.inline))
                .accessibilityValue(olderOpen ? "已展开" : "已折叠")
                .id(OlderGroup.anchor).padding(.bottom, titled || !olderOpen ? 0 : metrics.olderGap)
                if olderOpen {
                    ForEach(older, id: \.period) { group in
                        if titled { OlderGroupHeader(group: group) }
                        rows(group.cards)
                    }
                }
            }
        }
    }

    #if os(iOS)
    /// 系统放大转场走完（约半秒）再留一点余量。
    private static var zoomSettle: Duration { .milliseconds(700) }
    #endif

    private func add() {
        guard !adding else { return }
        adding = true
        let project = data.project?.id ?? Project.defaultID
        workspace.attempt {
            defer { adding = false }
            let card = try await workspace.createCard(in: project)
            #if os(iOS)
            born = card.id
            await NextFrame.wait()
            #endif
            workspace.open(card)
            #if os(iOS)
            try? await Task.sleep(for: Self.zoomSettle)
            born = nil
            #endif
        }
    }

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

private struct AddIdea: View {
    let data: ProjectPageData
    let action: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    var body: some View { AddIdeaTile(mood: mood, action: action) }

    private var mood: AddIdeaTile.Mood {
        let waits = data.tasks.ordered.contains { workspace.agent(of: $0.id, in: agents)?.shown.needsYou ?? false }
        if waits { return .waiting }
        return data.doneCount > 0 && data.tasks.isEmpty ? .done : .idea
    }
}

extension WallBoard {
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
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            #if os(macOS)
            Text(group.period.title()).font(Typography.label).foregroundStyle(palette.ink2)
            Spacer()
            Text("\(group.cards.count) 条").font(Typography.meta).foregroundStyle(palette.ink3)
            #else
            SectionHeader(Dotted(group.period.title()), level: .group)
            Spacer()
            #endif
        }
        .padding(.horizontal, Spacing.tight)
        #if os(macOS)
        .padding(.top, Spacing.page).padding(.bottom, Spacing.tight)
        #else
        .padding(.top, Spacing.group).padding(.bottom, Spacing.tight)
        #endif
        .frame(maxWidth: Spacing.reading, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct OlderRow: View {
    let entry: CardEntry

    var body: some View {
        let card = entry.card
        let shape = RoundedRectangle(cornerRadius: Radius.row)
        OlderRowLine(entry: entry)
            .modifier(OlderRowOpens(card: card, shape: shape))
            .contextMenu { CardActions(card: card, selectable: Self.selectable) }
            .cardDraggable(.idea(card.id), chip: entry.text.label, shape: shape)
    }

    #if os(macOS)
    private static let selectable = true
    #else
    private static let selectable = false
    static let inset = Spacing.group
    #endif
}

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
            .buttonStyle(RowOpenStyle())
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

private struct OlderRowLine: View {
    let entry: CardEntry
    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(Workspace.self) private var workspace
    #endif

    var body: some View {
        let card = entry.card, text = entry.text, attached = !text.attachments.isEmpty
        HStack(alignment: Look.alignment, spacing: Spacing.item) {
            #if os(macOS)
            RowGlyph(attached: attached)
            #endif
            Look.titles {
                Text(text.label).font(Look.label).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
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
            Text(DateLabel.short(card.modifiedAt)).font(Look.date).frame(minWidth: Look.dateWidth, alignment: .trailing)
                #if os(macOS)
                .yieldsToReveal(when: !workspace.presses.isSelecting)
                #endif
        }
        .font(Look.base).foregroundStyle(palette.ink3)
        .modifier(OlderRowSurface(card: card.id))
    }

    private enum Look {
        #if os(macOS)
        static let base: Font? = Typography.meta
        static let alignment = VerticalAlignment.center
        static let titles = AnyLayout(HStackLayout(spacing: Spacing.item))
        static let label = Typography.bodyBold
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
        static let label = Typography.secondaryBold
        static let preview = Typography.meta
        static let marks = Typography.caption2
        static let date = Typography.caption
        static let dateWidth: CGFloat = 0
        static let gap = Spacing.item
        static let dotInset = -AgentDot.overhang
        #endif
    }
}

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

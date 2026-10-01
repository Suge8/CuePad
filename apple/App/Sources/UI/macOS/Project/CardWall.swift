#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 卡片墙：列数随宽度（理想列宽 260），分列由 `WallColumns` 决定并保持稳定——存新卡时新卡进最矮一列的顶部，
/// 同列的卡往下挪（有动画），别列的卡不动；只有列数变化或跨天重新排墙时重新分配。
struct WallGrid<Tile: View>: View {
    let ids: [UUID]
    let cards: [UUID: Card]
    /// 这次排墙的时间：变了（跨天重排）就按新顺序整体重新分列。
    let arrangedAt: Date?
    @ViewBuilder let tile: (Card) -> Tile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 最近量到的宽度。不是界面状态：侧栏开合时每帧都变，放进 @State 会让每帧都重算墙的 body。
    @State private var width = WidthBox()
    @State private var layout: WallColumns?

    private static var spacing: CGFloat { 16 }
    private static var idealColumnWidth: CGFloat { 260 }

    var body: some View {
        // 一层平铺的卡片交给 ColumnsLayout 摆位：卡片换列只是换位置，不换父视图，不会被重建
        ColumnsLayout(spacing: Self.spacing, columnCount: layout?.columns.count ?? 1) {
            ForEach(placed, id: \.id) { item in
                if let card = cards[item.id] {
                    tile(card)
                        .layoutValue(key: ColumnKey.self, value: item.column)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 只在跨列数档位时重新分配：侧栏开合、拖窗口的其余帧只是列宽跟着变
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            let crossed = Self.count(for: newWidth) != Self.count(for: width.value)
            width.value = newWidth
            if crossed || layout == nil { relayout(animated: false) }
        }
        .onChange(of: ids) { relayout(animated: true) }
    }

    private var placed: [(id: UUID, column: Int)] {
        (layout?.columns ?? []).enumerated().flatMap { column, ids in ids.map { (id: $0, column: column) } }
    }

    private static func count(for width: CGFloat) -> Int {
        WallColumns.count(for: width, idealColumnWidth: idealColumnWidth, spacing: spacing)
    }

    private func relayout(animated: Bool) {
        let width = width.value
        guard width > 0 else { return }
        let count = Self.count(for: width)
        let columnWidth = (width - Self.spacing * CGFloat(count - 1)) / CGFloat(count)
        let cards = cards
        let height = { (id: UUID) in cards[id].map { WallColumns.estimatedHeight(of: CardText($0.body), columnWidth: columnWidth) } ?? 0 }
        var next = layout ?? WallColumns(order: ids, count: count, height: height, arrangedAt: arrangedAt)
        next.update(order: ids, count: count, height: height, arrangedAt: arrangedAt)
        guard next != layout else { return }
        if animated {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { layout = next }
        } else {
            layout = next
        }
    }
}

private final class WidthBox {
    var value: CGFloat = 0
}

nonisolated private struct ColumnKey: LayoutValueKey {
    static let defaultValue = 0
}

/// 按子视图标注的列号竖排：每列从上往下依次叠放，列宽均分。
private struct ColumnsLayout: Layout {
    let spacing: CGFloat
    let columnCount: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    // 没有对齐参考线：默认实现会把问题递归问遍墙上每张卡的子树，侧栏开合时每帧一次
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let count = max(columnCount, 1)
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var tops = Array(repeating: CGFloat.zero, count: count)
        return subviews.map { subview in
            let column = min(subview[ColumnKey.self], count - 1)
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: tops[column], width: columnWidth, height: height)
            tops[column] += height + spacing
            return frame
        }
    }
}

/// 墙上的一张卡：标题、首图、摘要、元信息（时间、块数、发送目标、浮回与置顶标记）。
struct CardTile: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    let isGoal: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let text = CardText(card.body)
        let isOpen = workspace.openCard == card.id
        Button(action: open) {
        VStack(alignment: .leading, spacing: 8) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-8).padding(.bottom, 6)
            }
            Text(text.title.isEmpty ? "空白卡片" : text.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                .lineLimit(2)
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? 4 : 2)
            }
            CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated, isGoal: isGoal)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 16, lifted: hovering)
        .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(CardPressStyle())
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .opacity(isOpen ? 0 : 1)
        .cardFrameSource(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardMenu(card: card, isGoal: isGoal) }
        .accessibilityElement(children: .combine)
    }

    private func open() {
        workspace.openCard = card.id
    }
}

/// 卡片右键菜单。
struct CardMenu: View {
    let card: Card
    let isGoal: Bool
    @Environment(Workspace.self) private var workspace
    @State private var projects: [Project]?

    var body: some View {
        let id = card.id
        Button("打开") { workspace.openCard = id }
        Button(card.isPinned ? "取消置顶" : "置顶") {
            let pinned = !card.isPinned
            workspace.perform { try await $0.updateCard(id) { $0.isPinned = pinned } }
        }
        if let project = card.projectID {
            Button(isGoal ? "取消项目目标" : "设为项目目标") {
                let goal = isGoal ? nil : id
                workspace.perform { try await $0.setGoal(goal, for: project) }
            }
        }
        Divider()
        Button("复制") { Task { await workspace.send(Outgoing.text(of: card), via: .clipboard, card: id) } }
        let choice = workspace.effectiveChoice(for: card.projectID)
        Button("发给 \(workspace.label(for: choice))") {
            Task { await workspace.send(Outgoing.text(of: card), via: choice, card: id) }
        }
        Button("转为任务") {
            let title = CardText(card.body).title, project = card.projectID
            workspace.attempt {
                _ = try await workspace.createTask(title.isEmpty ? "未命名任务" : title, in: project)
                try await workspace.services.store.trashCard(id)
            }
            workspace.say("已转为任务，原卡片在回收站")
        }
        Menu("移到项目") {
            ForEach(projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: project.id, after: nil) } }
                    .disabled(project.id == card.projectID)
            }
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: nil, after: nil) } }
                .disabled(card.projectID == nil)
        }
        .task { projects = try? await workspace.services.store.projects() }
        Divider()
        Button("移到回收站", role: .destructive) {
            if workspace.openCard == id { workspace.openCard = nil }
            workspace.perform { try await $0.trashCard(id) }
        }
    }
}

#endif

#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 卡片墙：列数随宽度（理想列宽 260），分列由 `WallColumns` 决定并保持稳定——存新卡时新卡进最矮一列的顶部，
/// 同列的卡往下挪（有动画），别列的卡不动；跨天重新排墙时按新顺序重新分配；窗口跨列数档位时换用该列数的分列。
struct WallGrid<Tile: View>: View {
    let ids: [UUID]
    let cards: [UUID: Card]
    /// 这次排墙的时间：变了（跨天重排）就按新顺序整体重新分列。
    let arrangedAt: Date?
    @ViewBuilder let tile: (Card) -> Tile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 每种列数各自的稳定分列。列数由 ColumnsLayout 按排版时拿到的宽度当场决定，这里不读几何：
    /// 几何读数写回状态再改布局，遇上滚动条出没、工具栏变化这类会反过来改宽度的事，就会来回翻转。
    @State private var arrangements: [Int: WallColumns] = [:]

    private static var spacing: CGFloat { 16 }
    private static var idealColumnWidth: CGFloat { 260 }
    /// 2560 宽的全屏收起侧栏是 9 列，留出余量。
    private static var maxColumns: Int { 12 }

    var body: some View {
        // 一层平铺的卡片交给 ColumnsLayout 摆位：卡片换列只是换位置，不换父视图，不会被重建
        ColumnsLayout(spacing: Self.spacing, idealColumnWidth: Self.idealColumnWidth, arrangements: arrangements.mapValues(\.columns)) {
            ForEach(ids, id: \.self) { id in
                if let card = cards[id] {
                    tile(card)
                        .layoutValue(key: CardIDKey.self, value: id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: ids, initial: true) { old, _ in rearrange(animated: old != ids && !arrangements.isEmpty) }
    }

    private func rearrange(animated: Bool) {
        let cards = cards
        let height = { (id: UUID) in cards[id].map { WallColumns.estimatedHeight(of: CardText($0.body), columnWidth: Self.idealColumnWidth) } ?? 0 }
        var next = arrangements
        for count in 1...Self.maxColumns {
            if next[count] == nil {
                next[count] = WallColumns(order: ids, count: count, height: height, arrangedAt: arrangedAt)
            } else {
                next[count]?.update(order: ids, count: count, height: height, arrangedAt: arrangedAt)
            }
        }
        guard next != arrangements else { return }
        if animated {
            withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) { arrangements = next }
        } else {
            arrangements = next
        }
    }
}

nonisolated private struct CardIDKey: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

/// 卡片墙的排版：按拿到的宽度定列数（理想列宽附近），取该列数的稳定分列，每列从上往下叠放，列宽均分。
/// 纯排版计算，不写任何状态。
private struct ColumnsLayout: Layout {
    let spacing: CGFloat
    let idealColumnWidth: CGFloat
    let arrangements: [Int: [[UUID]]]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? idealColumnWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).values.map(\.maxY).max() ?? 0)
    }

    // 没有对齐参考线：默认实现会把问题递归问遍墙上每张卡的子树，侧栏开合时每帧一次
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard let frame = frames[index] else { continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// 子视图下标 → 位置。分列里没有的卡（刚出现、分列还没跟上的那一帧）不摆。
    private func frames(width: CGFloat, subviews: Subviews) -> [Int: CGRect] {
        let count = min(WallColumns.count(for: width, idealColumnWidth: idealColumnWidth, spacing: spacing), arrangements.keys.max() ?? 1)
        guard let columns = arrangements[count] else { return [:] }
        let index = Dictionary(subviews.indices.compactMap { i in subviews[i][CardIDKey.self].map { ($0, i) } }, uniquingKeysWith: { first, _ in first })
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var frames: [Int: CGRect] = [:]
        for (column, ids) in columns.enumerated() {
            var top: CGFloat = 0
            for id in ids {
                guard let i = index[id] else { continue }
                let height = subviews[i].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
                frames[i] = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: top, width: columnWidth, height: height)
                top += height + spacing
            }
        }
        return frames
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
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card) }
        .accessibilityElement(children: .combine)
        #if DEBUG
        .onAppear { PerfProbe.mark("content") }
        #endif
    }

    private func open() {
        workspace.openCard = card.id
    }
}

#endif

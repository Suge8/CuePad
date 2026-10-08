#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 卡片墙：列数随宽度（理想列宽 260），分列由 `WallColumns` 决定并保持稳定——存新卡时新卡进最矮一列的顶部，
/// 同列的卡往下挪（有动画），别列的卡不动；跨天重新排墙时按新顺序重新分配；窗口跨列数档位时换用该列数的分列。
/// 减弱动态效果时不挪位：整面墙原地淡入淡出。
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
    /// 减弱动态效果时，每次带动画的重排换一个身份：整面墙原地淡入淡出，而不是卡片挪位
    @State private var fadeGeneration = 0

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
        .id(fadeGeneration)
        .transition(.opacity)
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
        if animated, reduceMotion {
            withAnimation(Motion.spatial(Motion.move, reduceMotion: true)) {
                arrangements = next
                fadeGeneration += 1
            }
        } else if animated {
            withAnimation(Motion.move) { arrangements = next }
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

/// 点开纸页的原卡片（墙上卡片、"更早"的行、目标卡）的按压：点下的那一帧直接缩到 `Motion.pressKick`，余下到 `Motion.pressScale`
/// 缓动；打开后纸页准备的那几帧保持按下，纸从这个样子起飞；松开没打开（拖走、取消）就回弹。按下与否看这张卡的开合状态（`cardHeld`：
/// 鼠标按着——AppKit 分发按下事件时就记下，早于按钮识别——或已打开、纸页还在准备），按钮自己识别出的按下兜底。
/// 减弱动态效果时不缩放，只略微变淡。
struct CardOpenStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.cardHeld) private var held
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let reducedOpacity = 0.85

        var body: some View {
            let down = configuration.isPressed || held
            configuration.label
                .scaleEffect(down && !reduceMotion ? Motion.pressKick : 1)
                .opacity(down && reduceMotion ? Self.reducedOpacity : 1)
                .animation(down ? nil : Motion.press, value: down)
                .scaleEffect(down && !reduceMotion ? Motion.pressScale / Motion.pressKick : 1)
                .animation(Motion.press, value: down)
        }
    }
}

/// 卡面：首图、标题、摘要、元信息（时间、发送目标、浮回、任务与资料标记）。墙上的卡与纸页过渡中纸上写的字共用，
/// 纸盖上原卡片、缩回原卡片的那一帧两者一模一样。
struct CardFace: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(card.body)
        VStack(alignment: .leading, spacing: 8) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-8).padding(.bottom, 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text.title.isEmpty ? "无标题" : text.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                AgentDot(card: card.id)
            }
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? 4 : 2)
            }
            CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated)
                .padding(.top, 2)
        }
        .padding(14)
    }
}

/// 墙上的一张卡（卡面见 `CardFace`）。
struct CardTile: View {
    /// 卡片的圆角；纸页从这个圆角起飞、缩回到这个圆角。
    static let radius: CGFloat = 16

    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
        CardFace(card: card, lastTarget: lastTarget, floated: floated)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: Self.radius, lifted: hovering)
        .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(CardOpenStyle())
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card) }
        .ideaDrag(card.id)
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

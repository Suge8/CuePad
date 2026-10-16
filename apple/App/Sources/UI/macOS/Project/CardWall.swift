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
        // 每张卡的高度只估一次：下面要为每种列数各分一次列，逐次估的话同一段正文要解析十几遍
        let heights = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, cards[id].map { WallColumns.estimatedHeight(of: CardText($0.body), columnWidth: Self.idealColumnWidth) } ?? 0)
        })
        let height = { (id: UUID) in heights[id] ?? 0 }
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
            withAnimation(Motion.crossfade) {
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

    /// 排版结果按宽度记一份：同一轮排版里 SwiftUI 先量（`sizeThatFits`）再摆（`placeSubviews`），每张卡的高度只量一遍。
    /// 子视图或分列变了，SwiftUI 会换一份新的缓存。
    final class Memo {
        var width: CGFloat?
        var frames: [Int: CGRect] = [:]
    }

    func makeCache(subviews: Subviews) -> Memo { Memo() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGSize {
        let width = fit(proposal.width).width
        return CGSize(width: width, height: frames(width: width, subviews: subviews, memo: cache).values.map(\.maxY).max() ?? 0)
    }

    private func fit(_ proposed: CGFloat?) -> (width: CGFloat, count: Int) {
        WallColumns.fit(proposed, ideal: idealColumnWidth, columnWidth: idealColumnWidth, spacing: spacing, limit: arrangements.keys.max() ?? 1)
    }

    // 没有对齐参考线：默认实现会把问题递归问遍墙上每张卡的子树，侧栏开合时每帧一次
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) {
        let frames = frames(width: bounds.width, subviews: subviews, memo: cache)
        for (index, subview) in subviews.enumerated() {
            guard let frame = frames[index] else { continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// 子视图下标 → 位置。分列里没有的卡（刚出现、分列还没跟上的那一帧）不摆。
    private func frames(width: CGFloat, subviews: Subviews, memo: Memo) -> [Int: CGRect] {
        if memo.width == width { return memo.frames }
        let frames = frames(width: width, subviews: subviews)
        memo.width = width
        memo.frames = frames
        return frames
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [Int: CGRect] {
        let count = fit(width).count
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

/// 点开编辑页的卡（墙上卡片、"更早"的行）的按压：样子同 `PressStyle(.card)`（`PressFeedback`，Mac 是按下即压暗、松开即复原），
/// 只是按下与否看这张卡的按下状态（`cardHeld`：鼠标按着——AppKit 分发按下事件时就记下，早于按钮识别——或已打开、编辑页还在准备），
/// 按钮自己识别出的按下兜底：打开后编辑页还在准备的那几帧保持按下，编辑页淡入时松开；松开没打开（拖走、取消）就复原。
struct CardOpenStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Pressed(configuration: configuration)
    }

    private struct Pressed: View {
        let configuration: Configuration
        @Environment(\.cardHeld) private var held

        var body: some View {
            configuration.label
                .modifier(PressFeedback(pressed: configuration.isPressed || held, kind: .card))
        }
    }
}

/// 卡面：首图、标题、摘要、元信息（时间、发送目标、浮回、任务与资料标记）。单独一个视图：悬停只改卡的外框，卡面不随之重算。
private struct CardFace: View {
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
                Text(text.label)
                    .font(Typography.bodyStrong)
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                AgentDot(card: card.id)
            }
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(Typography.body).lineSpacing(Typography.lineSpacing).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? CardText.previewLines : 2)
            }
            CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated, font: Typography.meta)
                .padding(.top, 2)
        }
        .padding(16)
    }
}

/// 墙上的一张卡。
struct CardTile: View {
    /// 卡片的圆角。
    static let radius: CGFloat = 16

    let card: Card
    let lastTarget: String?
    let floated: Bool
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
        CardFace(card: card, lastTarget: lastTarget, floated: floated)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: Self.radius, lifted: hovering)
        .overlay { SelectedFrame(radius: Self.radius) }
        .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(CardOpenStyle())
        .overlay(alignment: .bottomTrailing) {
            if hovering { MakeTaskButton(card: card.id).padding(10).transition(.opacity) }
        }
        .cardPresence(card.id, in: workspace)
        .onHover { hovering = $0 }
        .onAppear { if DebugHooks.hovers(card) { hovering = true } }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardActions(card: card, selectable: true) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "设为任务", makeTask)
    }

    private func makeTask() {
        let id = card.id
        workspace.attempt { try await workspace.setTodo(id, true) }
    }

    private func open() {
        guard !workspace.presses.takesClick(on: card.id, command: NSEvent.modifierFlags.contains(.command)) else { return }
        workspace.open(card)
    }
}

/// 悬停在墙上一张卡时右下角露出的"设为任务"：灵感变成任务的那一下（第一行做标题，其余是它的正文，`CueStore.setTodo`），
/// 卡离开墙、出现在上面的任务里，行尾就是"开始"。圈是任务圈的样子，告诉你它会变成什么；批量选择时不出现（点按是选择）。
private struct MakeTaskButton: View {
    let card: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        if !workspace.presses.isSelecting {
            Button {
                let id = card
                workspace.attempt { try await workspace.setTodo(id, true) }
            } label: {
                HStack(spacing: 5) {
                    Circle().strokeBorder(hovering ? palette.onSignature : palette.ink2, lineWidth: 1.3).frame(width: 11, height: 11)
                    Text("设为任务").fontWeight(.medium)
                }
                .font(Typography.meta)
                .foregroundStyle(hovering ? palette.onSignature : palette.ink)
                .padding(.horizontal, 9).frame(height: 24)
                .background(hovering ? palette.signatureFill : palette.paperLit, in: .capsule)
                .overlay(Capsule().strokeBorder(palette.hair).opacity(hovering ? 0 : 1))
                .shadow(color: .black.opacity(palette.dark ? 0.3 : 0.08), radius: 6, y: 2)
                .contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .help("设为任务：第一行做任务名，其余成为交给 Agent 的话")
        }
    }
}

/// 批量选择里选上的卡：一圈签名色的边，右上角一个对勾。
private struct SelectedFrame: View {
    let radius: CGFloat
    @Environment(\.cardSelected) private var selected
    @Environment(\.palette) private var palette

    var body: some View {
        if selected {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.signature, lineWidth: 2)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(palette.onSignature, palette.signature)
                        .padding(10)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

#endif

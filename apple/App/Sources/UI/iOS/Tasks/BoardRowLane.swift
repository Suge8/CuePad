#if os(iOS)
import SwiftUI

/// 手机竖屏看板的一行：行头同列头是一个组件（`BoardColumnHeader`），靠左排、不垫玻璃；下面一条横滑的卡，和列里是同一张卡。
/// 行头的字与卡里的字同一条左缘。一行里的卡一样高（`BoardCardLayout` 在行里固定三行）：卡高各异时横着排成锯齿。
/// 滚动区不裁内容：卡换行时飞过行的上下沿，横向超出的在屏幕外。
///
/// 一屏宽是一小列，从上往下排满再排下一小列：露全的那一小列就是这一行最前的几张。小列里的卡上下让位；
/// 排到另一小列去的卡是这一列撤一张、那一列添一张，淡出淡入、不飞——斜着横穿一屏的那一下不说明任何事，
/// 排数一变（页面的余高换了分法）或前面插进一张，每个小列的尾巴都要这样挪。
/// 否决过 `LazyHGrid`：它把换格当成同一张卡挪位置，一次重排满屏斜着飞；挪到没排出来的格子去的那张还会在别的行上停半秒（实测）。
struct BoardRowLane<Content: View>: View {
    let column: TaskBoard.Column
    let count: Int
    let archives: Bool
    let targeted: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.boardMoves) private var moves
    @State private var lead = 0
    /// 一格的高，量出来的（`BoardRowRuler`）：写死的数只对一种字——界面字取到圆体时行高一档，卡比格高，上下两排贴在一起（实测）。
    /// 量的那把尺不随这个数变，不成环；量到之前不排卡。
    @State private var full: CGFloat = 0
    @State private var slim: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardColumnHeader(column: column, count: count, archives: archives, shelf: true)
                .padding(.leading, BoardRowMetrics.margin + TaskMetrics.cardPadding).padding(.trailing, BoardRowMetrics.margin)
            if cell > 0 { strip }
        }
        .padding(.bottom, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted).padding(.horizontal, BoardRowMetrics.inset) }
        .background { BoardRowRuler(light: column.light).hidden().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 } }
        .background { BoardRowRuler(light: true).hidden().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slim = $0 } }
        .layoutValue(key: BoardRowFlex.self, value: flex)
    }

    private var cell: CGFloat { count == 0 && slim > 0 ? slim : full }

    private var flex: BoardRowFlex? {
        let rank: Int? = switch column {
        case .advancing: 0
        case .todo: 1
        case .waiting: 2
        case .done: nil
        }
        guard let rank, count > 1, cell > 0 else { return nil }
        return BoardRowFlex(step: cell + BoardRowMetrics.gap, most: count, rank: rank)
    }

    private var strip: some View {
        GeometryReader { geometry in
            let tiers = max(1, Int((geometry.size.height + BoardRowMetrics.gap + 0.5) / (cell + BoardRowMetrics.gap)))
            // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: BoardRowMetrics.gap) {
                        Group(subviews: content) { cards in
                            ForEach(0..<(cards.count + tiers - 1) / tiers, id: \.self) { stack in
                                VStack(spacing: BoardRowMetrics.gap) {
                                    ForEach(cards[stack * tiers..<min((stack + 1) * tiers, cards.count)]) { $0.frame(maxWidth: .infinity).frame(height: cell, alignment: .top) }
                                }
                                .boardStack(
                                    cards[stack * tiers..<min((stack + 1) * tiers, cards.count)].map(\.containerValues.boardFlight), in: column,
                                    height: cell, pitch: cell + BoardRowMetrics.gap)
                                .containerRelativeFrame(.horizontal) { [share = cardShare] width, _ in (width * share).rounded() }
                                .scrollTransition(.interactive, axis: .horizontal) { [peek = BoardRowMetrics.peek] stack, phase in stack.opacity(phase.isIdentity ? 1 : peek) }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .safeAreaPadding(.horizontal, BoardRowMetrics.margin)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .boardLane(column)
                .scrollDismissesKeyboard(.immediately)
                .frame(height: geometry.size.height, alignment: .top)
                .environment(\.boardRow, true)
                .onScrollTargetVisibilityChange(idType: Int.self) { lead = $0.first ?? lead }
                .task(id: moves?.pull.flatMap { $0.column == column ? $0.edge : nil }) {
                    guard let edge = moves?.pull.flatMap({ $0.column == column ? $0.edge : nil }), edge == .trailing || edge == .leading else { return }
                    while (try? await Task.sleep(for: Self.dwell)) != nil {
                        let next = lead + (edge == .trailing ? 1 : -1)
                        guard next >= 0 else { return }
                        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(next, anchor: .leading) } completion: { moves?.reaim() }
                    }
                }
            }
        }
        .frame(minHeight: cell, idealHeight: cell, maxHeight: .infinity)
    }

    private static var dwell: Duration { .milliseconds(450) }

    private var cardShare: CGFloat { typeSize.isAccessibilitySize ? BoardRowMetrics.wideCardWidth : BoardRowMetrics.cardWidth }
}

private struct BoardRowRuler: View {
    let light: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let title = Text(verbatim: "国").lineLimit(BoardCardMetrics.rowLines(typeSize), reservesSpace: true)
        Group {
            if light {
                title.font(TaskMetrics.lineFont).padding(.vertical, BoardCardMetrics.compactPad).frame(minHeight: ControlSize.regular.height)
            } else {
                VStack(alignment: .leading, spacing: BoardCardMetrics.footGap) {
                    title.font(Typography.bodyStrong)
                    Text(verbatim: "国").font(TaskMetrics.caption)
                    Color.clear.frame(width: 0).boardFootHeight(BoardCardMetrics.vitals)
                }
                .padding(.vertical, BoardCardMetrics.pad)
            }
        }
        .fixedSize()
    }
}

nonisolated struct BoardRowFlex: LayoutValueKey {
    static let defaultValue: BoardRowFlex? = nil
    let step: CGFloat
    let most: Int
    let rank: Int
}

enum BoardRowMetrics {
    static let peek = 0.5
    static let cardWidth: CGFloat = 0.72
    static let wideCardWidth: CGFloat = 0.9
    static let header = ControlSize.compact.height
    static let margin = Spacing.block
    static let gap = Spacing.group
    static let inset = Spacing.tight
}
#endif

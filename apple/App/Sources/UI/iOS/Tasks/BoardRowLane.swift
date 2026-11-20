#if os(iOS)
import SwiftUI

/// 手机竖屏看板的一行：行头同列头是一个组件（`BoardColumnHeader`），靠左排、不垫玻璃；下面一条横滑的卡，和列里是同一张卡。
/// 行头的字与卡里的字同一条左缘。一行里的卡一样高（`BoardCardLayout` 在行里固定三行）：卡高各异时横着排成锯齿。
/// 滚动区不裁内容：卡换行时飞过行的上下沿，横向超出的在屏幕外。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）。
struct BoardRowLane<Above: View, Content: View>: View {
    let column: TaskBoard.Column
    let count: Int
    let archives: Bool
    let targeted: Bool
    let rewind: UUID?
    /// 这一行至多排几排：页面有余高时才排到这么多（`BoardRows` 按 `BoardRowFlex` 分）。
    let tiers: Int
    @ViewBuilder let above: Above
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var advancingHeight = BoardRowMetrics.advancingHeight
    @ScaledMetric(relativeTo: .subheadline) private var waitingHeight = BoardRowMetrics.waitingHeight
    @ScaledMetric(relativeTo: .subheadline) private var lightHeight = BoardRowMetrics.lightHeight
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardColumnHeader(column: column, count: count, archives: archives, shelf: true)
                .padding(.leading, BoardRowMetrics.margin + TaskMetrics.cardPadding).padding(.trailing, BoardRowMetrics.margin)
            above.padding(.horizontal, BoardRowMetrics.margin).padding(.bottom, BoardRowMetrics.gap)
            strip
        }
        .padding(.bottom, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted).padding(.horizontal, BoardRowMetrics.inset) }
        .layoutValue(key: BoardRowFlex.self, value: tiers > 1 ? BoardRowFlex(step: cellHeight + BoardRowMetrics.gap, most: tiers) : nil)
    }

    private var strip: some View {
        let cell = cellHeight
        let tier = tiers > 1 ? GridItem(.adaptive(minimum: cell, maximum: cell), spacing: BoardRowMetrics.gap) : GridItem(.fixed(cell))
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: [tier], spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡：卡、空格与"更早做完的"铺满格
                    Group { content }
                        .containerRelativeFrame(.horizontal) { [share = cardShare] width, _ in (width * share).rounded() }
                        .frame(maxHeight: .infinity, alignment: .top)
                        // 没露全的那一张退后半步：右缘的半张卡不同整张的抢
                        .scrollTransition(.interactive, axis: .horizontal) { [peek = BoardRowMetrics.peek] card, phase in card.opacity(phase.isIdentity ? 1 : peek) }
                }
                .scrollTargetLayout()
            }
            .safeAreaPadding(.horizontal, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .boardLane(column)
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: cell, idealHeight: cell, maxHeight: .infinity)
            .environment(\.boardRow, true)
            .onChange(of: rewind, initial: true) {
                if let rewind { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 辅助字号下一张卡几乎占满可见宽：窄卡里大字一行只放得下几个字。
    private var cardShare: CGFloat { typeSize.isAccessibilitySize ? BoardRowMetrics.wideCardWidth : BoardRowMetrics.cardWidth }

    private var cellHeight: CGFloat {
        switch column {
        case .advancing: advancingHeight
        case .waiting: waitingHeight
        case .todo, .done: lightHeight
        }
    }
}

/// 有余高时多排几排的那一行（推进中）：每多一排要 `step` 高，至多 `most` 排。
nonisolated struct BoardRowFlex: LayoutValueKey {
    static let defaultValue: BoardRowFlex? = nil
    let step: CGFloat
    let most: Int
}

enum BoardRowMetrics {
    /// 一行里卡的高：推进中三行（标题、近况那一句、卡脚），等你的问句两行，待办与已完成只有标题与卡脚。
    static let advancingHeight: CGFloat = 92
    static let waitingHeight: CGFloat = 110
    static let lightHeight: CGFloat = 72
    static let peek = 0.5
    /// 露出下一张的开头：看得出能横滑。
    static let cardWidth: CGFloat = 0.72
    static let wideCardWidth: CGFloat = 0.9
    static let header: CGFloat = 44
    static let margin = Spacing.block
    static let gap = Spacing.item
    static let inset = Spacing.tight
}
#endif

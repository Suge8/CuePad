#if os(iOS)
import SwiftUI

/// 手机竖屏看板的一行：行头同列头是一个组件（`BoardColumnHeader`），靠左排、不垫玻璃；下面一条横滑的卡，和列里是同一张卡。
/// 行头的字与卡里的字同一条左缘。一行里的卡一样高（`BoardCardLayout` 在行里固定三行）：卡高各异时横着排成锯齿。
/// 滚动区不裁内容：卡换行时飞过行的上下沿，横向超出的在屏幕外。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）。
///
/// 一屏宽是一小列，从上往下排满再排下一小列：露全的那一小列就是这一行最前的几张。小列里的卡上下让位；
/// 排到另一小列去的卡是这一列撤一张、那一列添一张，淡出淡入、不飞——斜着横穿一屏的那一下不说明任何事，
/// 排数一变（页面的余高换了分法）或前面插进一张，每个小列的尾巴都要这样挪。
/// 否决过 `LazyHGrid`：它把换格当成同一张卡挪位置，一次重排满屏斜着飞；挪到没排出来的格子去的那张还会在别的行上停半秒（实测）。
struct BoardRowLane<Above: View, Content: View>: View {
    let column: TaskBoard.Column
    /// 这一行有几张卡：页面有余高时至多排这么多排，一屏露全（`BoardRows` 按 `BoardRowFlex` 分）。
    let count: Int
    let archives: Bool
    let targeted: Bool
    /// 换了就回到行首（打开添加任务）。
    let rewind: UUID?
    @ViewBuilder let above: Above
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.boardMoves) private var moves
    /// 露全的那一小列是第几列：拖到屏幕边上时往旁边翻一列（`BoardMoves.Pull`）。
    @State private var lead = 0
    /// 一格的高，量出来的（`BoardRowRuler`）：写死的数只对一种字——界面字取到圆体时行高一档，卡比格高，上下两排贴在一起（实测）。
    /// 量的那把尺不随这个数变，不成环；量到之前不排卡。
    @State private var full: CGFloat = 0
    /// 薄条那一格的高：空着的行只占这么高，一句说明用不着一张卡的地方，省下的给有卡的行多排。
    /// 两把尺都常量着，行空不空在排版时当场挑：行高与卡的进出在同一个动画事务里换（等尺子量完再写回的话晚一帧、不带动画）。
    @State private var slim: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardColumnHeader(column: column, count: count, archives: archives, shelf: true)
                .padding(.leading, BoardRowMetrics.margin + TaskMetrics.cardPadding).padding(.trailing, BoardRowMetrics.margin)
            above.padding(.horizontal, BoardRowMetrics.margin).padding(.bottom, BoardRowMetrics.gap)
            if cell > 0 { strip }
        }
        .padding(.bottom, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted).padding(.horizontal, BoardRowMetrics.inset) }
        .background { BoardRowRuler(light: column.light).hidden().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { full = $0 } }
        .background { BoardRowRuler(light: true).hidden().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slim = $0 } }
        .layoutValue(key: BoardRowFlex.self, value: flex)
    }

    private var cell: CGFloat { count == 0 && slim > 0 ? slim : full }

    /// 余高先给谁多排：正在发生的，再是接下来能做的，最后是等你的（它本来就少，下一张已经露着头）；已完成不长。
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

    /// 排几排由分到的高定，在同一次排版里算（不经几何读数写回状态）：行高与小列的分法在同一个动画事务里换。
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
                                    // 卡、空格与"更早做完的"铺满格
                                    ForEach(cards[stack * tiers..<min((stack + 1) * tiers, cards.count)]) { $0.frame(maxWidth: .infinity).frame(height: cell, alignment: .top) }
                                }
                                .boardStack(
                                    cards[stack * tiers..<min((stack + 1) * tiers, cards.count)].map(\.containerValues.boardFlight), in: column,
                                    height: cell, pitch: cell + BoardRowMetrics.gap)
                                .containerRelativeFrame(.horizontal) { [share = cardShare] width, _ in (width * share).rounded() }
                                // 没露全的那一小列退后半步：右缘的半张卡不同整张的抢
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
                .onChange(of: rewind, initial: true) {
                    if rewind != nil { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(0, anchor: .leading) } }
                }
                .onScrollTargetVisibilityChange(idType: Int.self) { lead = $0.first ?? lead }
                .task(id: moves?.pull.flatMap { $0.column == column ? $0.edge : nil }) {
                    guard let edge = moves?.pull.flatMap({ $0.column == column ? $0.edge : nil }), edge == .trailing || edge == .leading else { return }
                    // 停在边上一会儿才翻，之后一下一下地翻：路过边上不翻，翻了有工夫看清到了哪
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

    /// 辅助字号下一张卡几乎占满可见宽：窄卡里大字一行只放得下几个字。
    private var cardShare: CGFloat { typeSize.isAccessibilitySize ? BoardRowMetrics.wideCardWidth : BoardRowMetrics.cardWidth }
}

/// 这一行的卡有多高：照行里那张卡的骨架（`BoardCardLayout`、`BoardWaitCard`）用同样的字与间距排一张空的，行按它的高分格。
/// 推进中、等你三行（标题、近况或问句那一句、卡脚）；待办与已完成是一行高的薄条（`light`），不低于一颗钮的点按高。
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

/// 有余高时能多排几排的行：每多一排要 `step` 高，至多 `most` 排；`rank` 小的先分。
nonisolated struct BoardRowFlex: LayoutValueKey {
    static let defaultValue: BoardRowFlex? = nil
    let step: CGFloat
    let most: Int
    let rank: Int
}

enum BoardRowMetrics {
    static let peek = 0.5
    /// 露出下一张的开头：看得出能横滑。
    static let cardWidth: CGFloat = 0.72
    static let wideCardWidth: CGFloat = 0.9
    /// 比一颗钮的点按高矮：行头的钮上下浮出去补足（`LaneAddButton`），省下的高凑给推进中多一排。
    static let header = ControlSize.compact.height
    static let margin = Spacing.block
    static let gap = Spacing.group
    static let inset = Spacing.tight
}
#endif

#if os(iOS)
import SwiftUI

/// 手机竖版看板的一行（`BoardColumn` 的 `row`，`PhoneBoard` 四行竖着排）：Mac 看板的一列转 90°——一行横贯全屏，
/// 行头（`BoardLaneMark`、竖排的名字、数）是一块竖窄的写字玻璃，贴着屏幕左边钉在行里、竖直居中，卡在它右边横着排，放不下就在这一行里横划、
/// 按卡停（`viewAligned`）；卡滑动时从玻璃下面过，不遮罩、不在它右沿裁掉（docs/ui.md 沉浸式的栏）。玻璃贴屏边、不留缝：留缝时停着的上一张卡的尾巴在缝里露出碎字。
/// 四行的玻璃一样大（`spineHeight`：放得下最长的名字三个字加记号与数），在行里竖直居中、内容在玻璃里居中；比玻璃高的行里，停着的上一张卡在玻璃上下露出一截尾巴。
/// 行没有底（`BoardLane`）：分组靠留白与行头。
/// 行多高由 `PhoneBoard` 按屏高给，卡多卡少、有没有都不改；这里只答最小高：待办、推进中叠两排、等你与已完成一排的最小格（`BoardRowMetrics`，随动态字体放大），
/// 不低于行头玻璃（名字总写全）。给得比最小高多时格跟着长高，长到再叠得下一排最小格就多叠一排（`adaptive`）；卡铺满格，按列填（读的顺序不变）。
/// 空行是一格铺满整行高的虚线框。卡上标题小一档、可折两行，推进中下面是线与状态词，等你是抬头、三行问句、选项或回答框（不铺满格，靠上）。
/// 行里的卡在懒加载的横排里，只建看得见的几张。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）；它占的高另加在最小高上，卡的格不变矮。添加时这一行先滑回行首。
struct BoardRowLane<Above: View, Content: View>: View {
    let column: TaskBoard.Column
    let count: Int
    let targeted: Bool
    /// 添加任务：这一行滑回行首（滑到这一格）。
    let rewind: AnyHashable?
    @ViewBuilder let above: Above
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var taskHeight = BoardRowMetrics.taskHeight
    @ScaledMetric(relativeTo: .subheadline) private var advancingHeight = BoardRowMetrics.advancingHeight
    @ScaledMetric(relativeTo: .body) private var waitHeight = BoardRowMetrics.waitHeight
    @ScaledMetric(relativeTo: .caption) private var spineHeight = BoardRowMetrics.spineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.lead).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .frame(minHeight: spineHeight, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            BoardRowSpine(column: column, count: count)
                .frame(width: BoardRowMetrics.spine, height: spineHeight)
                .glass(in: UnevenRoundedRectangle(bottomTrailingRadius: BoardRowMetrics.spine / 2, topTrailingRadius: BoardRowMetrics.spine / 2, style: .continuous))
        }
        .padding(.vertical, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted) }
    }

    private var strip: some View {
        let cell = cellHeight
        // 空行只有一格虚线框，铺满整行高；有卡时叠得下几排最小格就叠几排，格平分行高
        let tier = count == 0 ? GridItem(.flexible(), spacing: BoardRowMetrics.gap) : GridItem(.adaptive(minimum: cell), spacing: BoardRowMetrics.gap)
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: [tier], spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡：卡、空格与"更早做完的"铺满格，等你靠上
                    Group { content }
                        .containerRelativeFrame(.horizontal) { width, _ in (width * cellWidth).rounded() }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollTargetLayout()
            }
            // 边用 safeAreaPadding（键盘起落重排后 contentMargins 的边会丢）；左边让出行头，滑动时卡从它下面过
            .safeAreaPadding(.leading, BoardRowMetrics.lead)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.always, axes: .horizontal)
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: cell * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1), maxHeight: .infinity)
            // 等你的问句最多三行：格高是定的
            .lineLimit(BoardRowMetrics.questionLines)
            .environment(\.boardRow, true)
            .onChange(of: rewind) {
                if let rewind { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 最小高里叠几排：待办、推进中两排，其余一排。
    private var tiers: Int {
        switch column {
        case .todo, .advancing: 2
        case .waiting, .done: 1
        }
    }

    /// 一格最矮多高。
    private var cellHeight: CGFloat {
        switch column {
        case .advancing: advancingHeight
        case .waiting: waitHeight
        case .todo, .done: taskHeight
        }
    }

    /// 一格占这一行可见宽的多少：等你的卡宽，其余露出下一张的一半。
    private var cellWidth: CGFloat {
        column == .waiting && count > 0 ? BoardRowMetrics.waitWidth : BoardRowMetrics.cardWidth
    }
}

/// 一行里的尺寸（高随动态字体放大，`BoardRowLane` 的 `@ScaledMetric`）。
enum BoardRowMetrics {
    /// 待办、已完成一格最矮：两行小一档的标题。
    static let taskHeight: CGFloat = 60
    /// 推进中一格最矮：两行标题，下面是线与状态词。
    static let advancingHeight: CGFloat = 76
    /// 等你一格最矮：抬头、三行问句加依据、回答框（实测最高的一件）。
    static let waitHeight: CGFloat = 176
    static let questionLines = 3
    /// 一格占可见宽：一张半，下一张露出一半。
    static let cardWidth: CGFloat = 0.62
    static let waitWidth: CGFloat = 0.88
    /// 行头宽：记号、竖排的名字与数。
    static let spine: CGFloat = 32
    /// 行头玻璃的高（四行同一个，行至少这么高）：记号、三个字的竖排名与数，上下各留一点。
    static let spineHeight: CGFloat = 92
    /// 卡静止时离屏幕左边：行头加卡与卡之间的空，停着的上一张卡横向收在玻璃下面；比玻璃高的行里它在玻璃上下露出一截。
    static let lead: CGFloat = spine + gap
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 4
}

/// 行头玻璃里的内容：记号、竖着的名字、数，在玻璃里居中（玻璃在行里竖直居中，卡从它下面滑过）。行再矮也写全：没有按列的底色，认行靠这几个字。
private struct BoardRowSpine: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption) private var mark: CGFloat = 16

    var body: some View {
        VStack(spacing: 3) {
            BoardLaneMark(column: column, size: mark)
            VStack(spacing: -2) {
                ForEach(Array(column.title.enumerated()), id: \.offset) { Text(String($1)) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(palette.ink2)
            Text("\(count)").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(palette.ink).counting(count)
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

#if os(iOS)
import SwiftUI

/// 手机竖版看板的一行（`BoardColumn` 的 `row`，`PhoneBoard` 四行竖着排）：Mac 看板的一列转 90°——一行横贯全屏，
/// 行头（`BoardLaneMark`、竖排的名字、数）是一块竖窄的写字玻璃，贴着屏幕左边钉在行里、竖直居中，卡在它右边横着排，放不下就在这一行里横划、
/// 按卡停（`viewAligned`）；卡滑动时从玻璃下面过，不遮罩、不在它右沿裁掉（docs/ui.md 沉浸式的栏）。玻璃贴屏边、不留缝：留缝时停着的上一张卡的尾巴在缝里露出碎字。
/// 四行的玻璃一样宽、高与这一行的卡一样（内容在玻璃里居中）：停着的上一张卡收在玻璃下面，上下都不露尾巴——四块一样高时，高的行在玻璃上下
/// 露出上一张卡的碎字（实测，等你那一行最明显）。行至少放得下最长的名字（三个字）加记号与数（`spineHeight`）。行没有底（`BoardLane`）：分组靠留白与行头。
/// 一格多高按列定、随动态字体放大（`BoardRowStyle`）：卡上标题小一档、可折两行，推进中下面是线与状态词，等你是抬头、三行问句、选项或回答框。
/// 待办、推进中有两件以上叠两排（按列填，读的顺序不变），其余一排；空行与只有"更早做完的 N"的已完成行收成一排矮格；行高不低于行头玻璃（名字总写全）。
/// 卡多卡少不改行高（除了空与不空、一件与两件），行在下面增减，上面的行不动。行里的卡在懒加载的横排里，只建看得见的几张。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）；添加时这一行先滑回行首。
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
        // 矮行（一排矮格）长到玻璃那么高，空格、"更早做完的"那一格跟着长到行高
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.lead).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .frame(minHeight: spineHeight)
        .overlay(alignment: .leading) {
            BoardRowSpine(column: column, count: count)
                .frame(width: BoardRowMetrics.spine)
                .frame(maxHeight: .infinity)
                .glass(in: UnevenRoundedRectangle(bottomTrailingRadius: BoardRowMetrics.spine / 2, topTrailingRadius: BoardRowMetrics.spine / 2, style: .continuous))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted) }
    }

    private var strip: some View {
        let height = cellHeight
        let tiers = self.tiers
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.flexible(minimum: height), spacing: BoardRowMetrics.gap), count: tiers), spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡；卡自己定高（`BoardRowStyle`），空格与"更早做完的"长到行高
                    Group { content }
                        .containerRelativeFrame(.horizontal) { width, _ in (width * cellWidth).rounded() }
                        .frame(minHeight: height, maxHeight: .infinity, alignment: .top)
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
            .frame(minHeight: height * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1), maxHeight: .infinity)
            // 等你的问句最多三行：格高是定的
            .lineLimit(BoardRowMetrics.questionLines)
            .environment(\.boardRow, BoardRowStyle(cardHeight: taskHeight, advancingHeight: advancingHeight))
            .onChange(of: rewind) {
                if let rewind { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 叠几排：待办、推进中两件以上叠两排。
    private var tiers: Int {
        switch column {
        case .todo, .advancing: count >= 2 ? 2 : 1
        case .waiting, .done: 1
        }
    }

    /// 空行（只有一格空态）、只有"更早做完的"的已完成行是一排矮格。
    private var cellHeight: CGFloat {
        guard count > 0 else { return taskHeight }
        return switch column {
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
    /// 待办、已完成一格：两行小一档的标题。
    static let taskHeight: CGFloat = 60
    /// 推进中一格：两行标题，下面是线与状态词。
    static let advancingHeight: CGFloat = 76
    /// 等你一格：抬头、三行问句加依据、回答框（实测最高的一件）。
    static let waitHeight: CGFloat = 176
    static let questionLines = 3
    /// 一格占可见宽：一张半，下一张露出一半。
    static let cardWidth: CGFloat = 0.62
    static let waitWidth: CGFloat = 0.88
    /// 行头宽：记号、竖排的名字与数。
    static let spine: CGFloat = 32
    /// 行至少这么高：行头玻璃里放得下记号、三个字的竖排名与数，上下各留一点。
    static let spineHeight: CGFloat = 92
    /// 卡静止时离屏幕左边：行头加卡与卡之间的空，停着的上一张卡正好整个收在玻璃下面。
    static let lead: CGFloat = spine + gap
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 8
}

/// 行的左端：记号、竖着的名字、数，与第一排卡的上沿齐，卡从它右边滑过。行再矮也写全：没有按列的底色，认行靠这几个字。
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

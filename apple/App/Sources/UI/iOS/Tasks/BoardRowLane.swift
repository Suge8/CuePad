#if os(iOS)
import SwiftUI

/// 手机竖版看板的一行（`BoardColumn` 的 `row`，`PhoneBoard` 四行竖着排）：Mac 看板的一列转 90°——一行横贯全屏，
/// 行头（`BoardLaneMark`、竖排的名字、数）是一块竖窄的写字玻璃，贴着屏幕左边钉在行里、竖直居中，卡在它右边横着排，放不下就在这一行里横划、
/// 按卡停（`viewAligned`）；卡滑动时从玻璃下面过，不遮罩、不在它右沿裁掉（docs/ui.md 沉浸式的栏）。玻璃贴屏边、不留缝：留缝时停着的上一张卡的尾巴在缝里露出碎字。
/// 四行的玻璃一样大（至少 `spineHeight`，名字那一格按四个名字里最长的占位），在行里竖直居中、内容在玻璃里居中；比玻璃高的行里，停着的上一张卡在玻璃上下露出一截尾巴。
/// 行没有底（`BoardLane`）：分组靠留白与行头。
/// 行多高由 `PhoneBoard` 按屏高给，卡多卡少、有没有都不改；这里只答最小高：待办、推进中、等你叠两排、已完成一排的最小格（`BoardRowMetrics`，随动态字体放大），
/// 不低于行头玻璃（名字总写全）。给得比最小高多时格跟着长高，长到再叠得下一排最小格就多叠一排（`adaptive`）；卡铺满格，按列填（读的顺序不变）。
/// 空行是一格铺满整行高的虚线框。卡上标题小一档、可折两行，推进中下面是线与状态词。
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
    @ScaledMetric(relativeTo: .caption) private var spineHeight = BoardRowMetrics.spineHeight

    var body: some View {
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.lead).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .frame(minHeight: spineHeight, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            BoardRowSpine(column: column, count: count)
                .frame(width: BoardRowMetrics.spine)
                .frame(minHeight: spineHeight)
                .fixedSize(horizontal: false, vertical: true)
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
                    // Group 把格子的框分给里面的每一张卡：卡、空格与"更早做完的"铺满格
                    Group { content }
                        .containerRelativeFrame(.horizontal) { width, _ in (width * BoardRowMetrics.cardWidth).rounded() }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollTargetLayout()
            }
            // 边用 safeAreaPadding（docs/ui.md 布局约束）；左边让出行头，滑动时卡从它下面过
            .safeAreaPadding(.leading, BoardRowMetrics.lead)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: cell * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1), maxHeight: .infinity)
            .environment(\.boardRow, true)
            .onChange(of: rewind) {
                if let rewind { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 最小高里叠几排：已完成一排，其余两排。
    private var tiers: Int { column == .done ? 1 : 2 }

    /// 一格最矮多高。
    private var cellHeight: CGFloat {
        switch column {
        case .advancing: advancingHeight
        case .todo, .waiting, .done: taskHeight
        }
    }
}

/// 一行里的尺寸（高随动态字体放大，`BoardRowLane` 的 `@ScaledMetric`）。
enum BoardRowMetrics {
    /// 待办、等你、已完成一格最矮：两行小一档的标题。
    static let taskHeight: CGFloat = 60
    /// 推进中一格最矮：两行标题，下面是线与状态词。
    static let advancingHeight: CGFloat = 76
    /// 一格占可见宽：一张半，下一张露出一半。
    static let cardWidth: CGFloat = 0.62
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
            // 四行的玻璃一样高：名字那一格按最长的名字占位
            ZStack {
                ForEach(TaskBoard.Column.allCases) { Self.name($0.title).hidden() }
                Self.name(column.title)
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

    /// 汉字一字一行竖排；拉丁字母竖排读不成词，整词侧转 90°。
    @ViewBuilder private static func name(_ title: String) -> some View {
        if title.unicodeScalars.allSatisfy(\.properties.isIdeographic) {
            VStack(spacing: -2) {
                ForEach(Array(title.enumerated()), id: \.offset) { Text(String($1)) }
            }
        } else {
            Sideways { Text(title).lineLimit(1).fixedSize().rotationEffect(.degrees(-90)) }
        }
    }
}

/// 侧转 90° 的一个子视图占转过之后的框（`rotationEffect` 只转画面，不换排版的宽高）。
private struct Sideways: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: size.height, height: size.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: .unspecified)
    }
}
#endif

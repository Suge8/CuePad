#if os(iOS)
import SwiftUI

/// 手机竖版看板的一行（`BoardColumn` 的 `row`，`PhoneBoard` 四行竖着排）：Mac 看板的一列转 90°——一行横贯全屏，
/// 行头（`BoardLaneMark`、竖排的名字、数）是一块竖窄的写字玻璃，贴着屏幕左边钉在行里、竖直居中，卡在它右边横着排，放不下就在这一行里横划、
/// 按卡停（`viewAligned`）；卡滑动时从玻璃下面过，不遮罩、不在它右沿裁掉（docs/layout.md 沉浸式的栏）。玻璃贴屏边、不留缝：留缝时停着的上一张卡的尾巴在缝里露出碎字。
/// 行分轻重（`TaskBoard.Column`，`BoardWeight.swift`）：
/// - 推进中、等你：理想高叠三排最小格（`rowTiers`），行头玻璃随行高拉长、上下各让出 `spineInset`，记号、名字与放大的数在里面竖直居中；
/// - 待办、已完成：一排矮卡（`lightHeight`），行头与卡同高，记号与数并排在上、名字竖排在下，字小一档。
/// 行没有底（`BoardLane`）：分组靠留白、行头与卡的纸色。
/// 行多高由 `PhoneBoard` 按屏高给，卡多卡少、有没有都不改；这里只答两个高：理想高是上面那几排最小格（`BoardRowMetrics`，随动态字体放大），
/// 最矮是一排最小格；都不低于行头玻璃（名字总写全）。重的两行叠得下几排最小格就叠几排（`adaptive`），格平分行高；卡铺满格，按列填（读的顺序不变）。
/// 空行是一格铺满整行高的虚线框。卡上标题小一档、可折两行（`BoardCardMetrics.title`），推进中下面是线与状态词。
/// 辅助字号下一行只叠一排、一张卡几乎占满可见宽（下一张露一条边）：窄卡里大字一行只放得下两个字。
/// 行里的卡在懒加载的横排里，只建看得见的几张；卡换行时飞过行的上下沿（`boardFlight`），滚动区不裁内容（横向超出的在屏幕外）。
/// 添加任务那一行（`above`）横贯这一行、在卡的上面，不挤进格子里（格子窄，选项目的胶囊会被截）；它占的高另加在这一行的两个高上，卡的格不因它变矮。添加时这一行先滑回行首。
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
    @ScaledMetric(relativeTo: .subheadline) private var advancingHeight = BoardRowMetrics.advancingHeight
    @ScaledMetric(relativeTo: .subheadline) private var waitingHeight = BoardRowMetrics.waitingHeight
    @ScaledMetric(relativeTo: .caption2) private var lightHeight = BoardRowMetrics.lightHeight
    @ScaledMetric(relativeTo: .caption) private var spineHeight = BoardRowMetrics.spineHeight
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.lead).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .frame(minHeight: column.light ? lightHeight : spineHeight + 2 * BoardRowMetrics.spineInset, maxHeight: .infinity)
        .overlay(alignment: .leading) {
            BoardRowSpine(column: column, count: count)
                .frame(width: BoardRowMetrics.spine)
                .frame(minHeight: column.light ? lightHeight : spineHeight, maxHeight: column.light ? nil : .infinity)
                .fixedSize(horizontal: false, vertical: column.light)
                .glass(in: UnevenRoundedRectangle(bottomTrailingRadius: BoardRowMetrics.spine / 2, topTrailingRadius: BoardRowMetrics.spine / 2, style: .continuous))
                .padding(.vertical, column.light ? 0 : BoardRowMetrics.spineInset)
        }
        .padding(.vertical, BoardRowMetrics.inset)
        .background { BoardLane(targeted: targeted) }
    }

    private var strip: some View {
        let cell = cellHeight
        // 空行只有一格虚线框、轻的两行只一排，都铺满整行高；重的两行有卡时叠得下几排最小格就叠几排，格平分行高
        let tier = count == 0 || column.light ? GridItem(.flexible(), spacing: BoardRowMetrics.gap) : GridItem(.adaptive(minimum: cell), spacing: BoardRowMetrics.gap)
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: [tier], spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡：卡、空格与"更早做完的"铺满格
                    Group { content }
                        .containerRelativeFrame(.horizontal) { [share = cardShare] width, _ in (width * share).rounded() }
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollTargetLayout()
            }
            // 边用 safeAreaPadding（docs/layout.md）；左边让出行头，滑动时卡从它下面过
            .safeAreaPadding(.leading, BoardRowMetrics.lead)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .boardLane(column)
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: cell, idealHeight: cell * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1), maxHeight: .infinity)
            .environment(\.boardRow, true)
            .environment(\.boardTitle, BoardCardMetrics.title(column, cardWidth: nil, typeSize: typeSize))
            .onChange(of: rewind) {
                if let rewind { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 理想高里叠几排：辅助字号下一排，其余按列（`TaskBoard.Column.rowTiers`）。
    private var tiers: Int { typeSize.isAccessibilitySize ? 1 : column.rowTiers }

/// 一张卡占可见宽的几成。
    private var cardShare: CGFloat { typeSize.isAccessibilitySize ? BoardRowMetrics.wideCardWidth : BoardRowMetrics.cardWidth }

    /// 一格最矮多高。
    private var cellHeight: CGFloat {
        switch column {
        case .advancing: advancingHeight
        case .waiting: waitingHeight
        case .todo, .done: lightHeight
        }
    }
}

/// 一行里的尺寸（高随动态字体放大，`BoardRowLane` 的 `@ScaledMetric`）。
enum BoardRowMetrics {
    /// 推进中一格最矮：两行标题，下面是线与状态词。
    static let advancingHeight: CGFloat = 76
    /// 等你一格最矮：两行小一档的标题。
    static let waitingHeight: CGFloat = 60
    /// 待办、已完成一格（只一排）：两行小一档的标题；行头与它同高，记号与数一排、三个字的竖排名，上下各留六七点——
    /// 再矮行头就贴着玻璃上下沿，再高推进中、等你在 iPhone 17 上排不下三排（`PhoneBoard`）。
    static let lightHeight: CGFloat = 64
    /// 一格占可见宽：一张半，下一张露出一半。
    static let cardWidth: CGFloat = 0.62
    /// 辅助字号下：几乎一张占满，下一张露出一条边，看得出还能横划。
    static let wideCardWidth: CGFloat = 0.88
    /// 行头宽：记号、竖排的名字与数。
    static let spine: CGFloat = 32
    /// 推进中、等你行头玻璃最矮：记号、三个字的竖排名与放大的数，上下各留一点；行高了它跟着拉长，离行的上下沿各 `spineInset`。
    static let spineHeight: CGFloat = 92
    static let spineInset: CGFloat = 10
    /// 卡静止时离屏幕左边：行头加卡与卡之间的空，停着的上一张卡横向收在玻璃下面；比玻璃高的行里它在玻璃上下露出一截。
    static let lead: CGFloat = spine + gap
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 4
}

/// 行头玻璃里的内容，在玻璃里居中（玻璃在行里竖直居中，卡从它下面滑过）。行再矮也写全名字：认行靠记号、名字与纸色。
/// 重的两行：记号、竖排的名字、放大着状态色的数；轻的两行与矮卡同高，记号与数并排在上、名字竖排在下，字小一档，名字与数都是 ink3。
/// 名字那一格按四个名字里最长的占位，同轻重的行头一样大。
private struct BoardRowSpine: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption) private var mark: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var lightMark: CGFloat = 12

    var body: some View {
        Group {
            if column.light {
                VStack(spacing: 3) {
                    HStack(spacing: 2) {
                        BoardLaneMark(column: column, size: lightMark)
                        number.font(.caption2.weight(.semibold))
                    }
                    title.font(.caption2.weight(.semibold))
                }
            } else {
                VStack(spacing: 3) {
                    BoardLaneMark(column: column, size: mark)
                    title.font(.caption.weight(.semibold))
                    number.font(.headline)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityAddTraits(.isHeader)
    }

    private var title: some View {
        ZStack {
            ForEach(TaskBoard.Column.allCases) { Self.name($0.title).hidden() }
            Self.name(column.title)
        }
        .foregroundStyle(column.light ? palette.ink3 : palette.ink2)
    }

    private var number: some View {
        Text("\(count)").monospacedDigit().foregroundStyle(column.countInk(palette)).counting(count).minimumScaleFactor(0.7).lineLimit(1)
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

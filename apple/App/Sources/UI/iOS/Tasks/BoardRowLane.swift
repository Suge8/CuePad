#if os(iOS)
import SwiftUI

/// 一行横泳道排几排、卡占屏宽多少、行头在哪（`PhoneBoard` 的各排法）。
struct BoardRowShape: Equatable {
    /// 行里叠几排卡（等你只排一排：卡高）。
    var tiers: Int
    /// 一张卡占屏宽多少：下一张露出一截，看得出能横划。
    var width: CGFloat
    /// 行头竖排在行的左端（钉住，卡从它右边滑过）；否则是行顶一条。
    var spine = false
}

/// 手机任务页的一行（`BoardColumn` 给了 `row` 时）：Mac 看板的一列转 90°——按列上色的泳道横贯全屏，行头（`BoardLaneMark`、名字、数）在行顶或左端，
/// 卡在下面横着排，一排放不下就在这一行里横划、按卡停（`viewAligned`）。一行的高只看是哪一列（卡高 × 排数），与卡多卡少无关：
/// 答完最后一件、做完一件，行不缩，整页不在手下跳；空行是行里的一格空态。
/// 行里横划归这一行（整页 `claimsHorizontalDrags`），滑到头回弹；切页只认贴屏幕边起手。卡在懒加载的横排里，只建看得见的那几张。
struct BoardRowLane<Content: View>: View {
    let column: TaskBoard.Column
    let count: Int
    let shape: BoardRowShape
    let targeted: Bool
    /// 要滑到行首的那一格（添加任务那一行出现时）。
    let lead: String?
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if shape.spine {
                HStack(alignment: .top, spacing: 0) {
                    BoardRowSpine(column: column, count: count).frame(width: BoardRowMetrics.spine)
                    strip(leading: 0)
                }
                .padding(.vertical, BoardRowMetrics.inset)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    BoardRowHeader(column: column, count: count)
                    strip(leading: BoardRowMetrics.margin).padding(.bottom, BoardRowMetrics.inset)
                }
            }
        }
        .background { band }
    }

    private func strip(leading: CGFloat) -> some View {
        let height = BoardRowMetrics.cardHeight(column)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(height), spacing: BoardRowMetrics.gap), count: shape.tiers), spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡
                    Group { content }
                        .containerRelativeFrame(.horizontal) { width, _ in (width * shape.width).rounded() }
                        .frame(height: height, alignment: .top)
                }
                .scrollTargetLayout()
            }
            // 边用 safeAreaPadding（同看板原型的旧注释：键盘起落重排后 contentMargins 的边会丢）
            .safeAreaPadding(.leading, leading)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.always, axes: .horizontal)
            .scrollDismissesKeyboard(.immediately)
            .frame(height: height * CGFloat(shape.tiers) + BoardRowMetrics.gap * CGFloat(shape.tiers - 1))
            // 等你的问句最多三行：行高是定的
            .lineLimit(BoardRowMetrics.questionLines)
            .onChange(of: lead) {
                guard let lead else { return }
                withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(lead, anchor: .leading) }
            }
        }
    }

    /// 横贯全屏的一条：上沿一线高光（同 `BoardLane`），拖进来时铺一层选中底。
    private var band: some View {
        ZStack {
            palette.sheen
            column.lane(palette).padding(.top, 1)
            if targeted { palette.selection.transition(.opacity) }
        }
        .animation(HandOff.quick, value: targeted)
    }
}

/// 一行里的尺寸。
enum BoardRowMetrics {
    /// 一格卡多高：推进中带线的卡、等你（抬头、三行问句的气泡、回答框或选项）、其余一行标题的卡。
    static func cardHeight(_ column: TaskBoard.Column) -> CGFloat {
        switch column {
        case .advancing: BoardCardMetrics.advancingHeight
        case .waiting: waitHeight
        case .todo, .done: TaskMetrics.cardHeight
        }
    }

    /// 等你一格的高：放得下抬头、三行问句加依据、回答框（实测最高的一件）。
    static let waitHeight: CGFloat = 180
    static let questionLines = 3
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 10
    static let spine: CGFloat = 44
}

/// 行顶一条：记号、名字，右边是数（同 Mac 列头，矮一档）。
private struct BoardRowHeader: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            BoardLaneMark(column: column, size: 18)
            Text(column.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            Spacer(minLength: 8)
            Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(palette.ink).counting(count)
        }
        .lineLimit(1)
        .padding(.horizontal, BoardRowMetrics.margin + TaskMetrics.cardPadding)
        .frame(height: 40)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 行的左端竖排：记号、竖着的名字、数，钉在左边，卡从它右边滑过。
private struct BoardRowSpine: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            BoardLaneMark(column: column, size: 18)
            VStack(spacing: 0) {
                ForEach(Array(column.title.enumerated()), id: \.offset) { Text(String($1)) }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            Text("\(count)").font(.headline).monospacedDigit().foregroundStyle(palette.ink).counting(count)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityAddTraits(.isHeader)
    }
}
#endif

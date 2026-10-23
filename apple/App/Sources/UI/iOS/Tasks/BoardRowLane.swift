#if os(iOS)
import SwiftUI

/// 手机竖版看板的一行（`BoardColumn` 的 `row`，`PhoneBoard` 四行竖着排）：Mac 看板的一列转 90°——按列上色的泳道横贯全屏，
/// 行头（`BoardLaneMark`、竖排的名字、数）钉在左端，卡在它右边横着排，放不下就在这一行里横划、按卡停（`viewAligned`）；
/// 卡滑过行头时在它右沿淡出，不硬切。
/// 一格多高按列定、随动态字体放大（`BoardRowStyle`）：卡上标题小一档、可折两行，推进中下面是线与状态词，等你是抬头、三行问句、选项或回答框。
/// 待办、推进中有两件以上叠两排（按列填，读的顺序不变），其余一排；空行与只有"更早做完的 N"的已完成行收成一排矮格；行高只看格子，行头随行高收紧（`BoardRowSpine`）。
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

    var body: some View {
        // 行高只由格子定：行头叠在左边、拿到的就是这个高，放不下全名就收紧
        VStack(alignment: .leading, spacing: BoardRowMetrics.gap) {
            above.padding(.leading, BoardRowMetrics.fade).padding(.trailing, BoardRowMetrics.margin)
            strip
        }
        .padding(.leading, BoardRowMetrics.spine)
        .overlay(alignment: .leading) { BoardRowSpine(column: column, count: count).frame(width: BoardRowMetrics.spine) }
        .padding(.vertical, BoardRowMetrics.inset)
        .background { band }
    }

    private var strip: some View {
        let height = cellHeight
        let tiers = self.tiers
        // 回到行首用 ScrollViewReader，不绑 ScrollPosition：绑着的位置滑动时每帧写回状态，整行每帧重算
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(height), spacing: BoardRowMetrics.gap), count: tiers), spacing: BoardRowMetrics.gap) {
                    // Group 把格子的框分给里面的每一张卡
                    Group { content }
                        .containerRelativeFrame(.horizontal) { width, _ in (width * cellWidth).rounded() }
                        .frame(height: height, alignment: .top)
                }
                .scrollTargetLayout()
            }
            // 边用 safeAreaPadding（键盘起落重排后 contentMargins 的边会丢）；左边让出淡出那一截
            .safeAreaPadding(.leading, BoardRowMetrics.fade)
            .safeAreaPadding(.trailing, BoardRowMetrics.margin)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .scrollBounceBehavior(.always, axes: .horizontal)
            .scrollDismissesKeyboard(.immediately)
            .frame(height: height * CGFloat(tiers) + BoardRowMetrics.gap * CGFloat(tiers - 1))
            .mask { fadeMask }
            // 等你的问句最多三行：格高是定的
            .lineLimit(BoardRowMetrics.questionLines)
            .environment(\.boardRow, BoardRowStyle(cardHeight: taskHeight, advancingHeight: advancingHeight))
            .onChange(of: rewind) {
                if let rewind { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(rewind, anchor: .leading) } }
            }
        }
    }

    /// 卡滑到行头右沿时淡出：左边一截从透明到实，其余全实。
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: BoardRowMetrics.fade)
            Color.black
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
    static let spine: CGFloat = 34
    /// 卡滑到行头时淡出的那一截，也是卡离行头的空。
    static let fade: CGFloat = 6
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let inset: CGFloat = 8
}

/// 行的左端：记号、竖着的名字、数，与第一排卡的上沿齐，卡从它右边滑过。
/// 行矮（一排矮格：空行、只有"更早做完的 N"、一件待办）放不下竖排的名字时只留记号与数：行不为行头长高，名字由记号、行的颜色与格子里的字带出。
private struct BoardRowSpine: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var mark: CGFloat = 18

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 4) {
                BoardLaneMark(column: column, size: mark)
                VStack(spacing: -1) {
                    ForEach(Array(column.title.enumerated()), id: \.offset) { Text(String($1)) }
                }
                .font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                .padding(.top, 2)
                number
            }
            VStack(spacing: 4) {
                BoardLaneMark(column: column, size: mark)
                number
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.leading, BoardRowMetrics.fade)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityAddTraits(.isHeader)
    }

    private var number: some View {
        Text("\(count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(palette.ink).counting(count)
            .minimumScaleFactor(0.7).lineLimit(1)
    }
}
#endif

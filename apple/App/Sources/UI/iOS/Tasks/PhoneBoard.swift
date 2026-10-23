#if os(iOS)
import CueStore
import SwiftUI

/// 原型（proto/board-combo，不进主干）：窄屏任务页的竖版看板——Mac 看板转 90°：待办、推进中、等你、已完成四行竖着排，
/// 每行是一条横贯全屏的泳道（`BoardRowLane`），卡在行里横着排、放不下就在这一行里横划。页里不再有四个分段。
/// 横拖的归属（`PagerArbiter`）：整页认领横拖（`claimsHorizontalDrags`）——不贴边的横拖都是行的，滑到头只回弹；贴屏幕左右边起手才切页。
/// 四行常驻：一共四行，每行自己是懒加载的横排；整页放不下时竖着滚。点"+"添加任务时整页先回到待办那一行。
/// 排法按 `-CuePadProtoBoard`：
/// - A「两排、整页竖滚」：待办、推进中、已完成每行叠两排卡，等你一排；比一屏高，整页竖着滚。
/// - B「一屏放下」：待办叠两排、其余一排，四行加起来正好一屏（iPhone 17），不竖滚；矮的屏放不下时照样竖着滚。
/// - C「行头竖在左端」：同 A 的排数，行头钉在行的左端（Mac 列头转 90° 的样子），卡从它右边滑过。
struct PhoneBoard: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let style = DebugHooks.preset.protoBoard

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.gap) {
                    ForEach(TaskBoard.Column.allCases) { column in
                        BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject, row: shape(column)).id(column)
                    }
                }
                .claimsHorizontalDrags()
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            // 一滚就收键盘（等你行的回答框）：手机看板没有别处收得起它
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: adding) {
                if adding { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(TaskBoard.Column.todo, anchor: .top) } }
            }
        }
    }

    private func shape(_ column: TaskBoard.Column) -> BoardRowShape {
        let wide = column == .waiting
        let width: CGFloat = wide ? 0.84 : 0.66
        switch style {
        case "B": return BoardRowShape(tiers: column == .todo ? 2 : 1, width: width)
        case "C": return BoardRowShape(tiers: wide ? 1 : 2, width: width, spine: true)
        default: return BoardRowShape(tiers: wide ? 1 : 2, width: width)
        }
    }

    static let gap: CGFloat = 8
}
#endif

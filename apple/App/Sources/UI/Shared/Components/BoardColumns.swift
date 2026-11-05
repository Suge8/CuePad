import CueStore
import SwiftUI

/// 四列并排（Mac、宽屏 iPad 与 iPhone 横屏的进展页）：每列（`BoardColumn`）的列头浮在顶上（`BoardColumnHeader`，写字玻璃），卡各自滚动、从列头后面过。
/// 四列等分可见宽，一列不窄于 `BoardWidths.minColumn`：不按卡多卡少、列空不空分宽，换卡、拖窗口时列宽只随窗口变。
/// 四列总在眼前，放不下时（如 Mac 窄窗开着侧栏）整排横向滚动、最右一列露出一截（看得出能横划）：两侧页边是滚动区内容的边（`margin`），
/// 列滚到窗口边才裁，滚到头右边照样留页边。卡换列时从原处飞到新处（`boardFlight`），四列共用量飞行位置的坐标系与正被拖着的那件（`boardStage`）。
struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 两侧页边。
    let margin: CGFloat
    /// 已完成列末尾"更早做完的"展开着。
    @State private var showsEarlier = DebugHooks.preset.showsDone

    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
    @Environment(\.boardBand) private var band
    #endif

    var body: some View {
        // 按可见宽算一次列宽与卡标题的行数，每列的卡都用这一份（几何读数只给子视图，不写回状态）
        GeometryReader { proxy in
            let width = BoardWidths.column(room: proxy.size.width - margin * 2)
            // 放得下、放不下都是这一个滚动区（放得下时只是滚不动）：窗口拖过四列最窄时不换结构，列里的滚动位置留着
            ScrollView(.horizontal) { columns(width) }
                .safeAreaPadding(.horizontal, margin)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                .boardStage()
        }
    }

    private func columns(_ width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: BoardWidths.gap) {
            ForEach(TaskBoard.Column.allCases, id: \.self) { item in
                BoardColumn(column: item, board: board, adding: $adding, newTaskProject: newTaskProject, earlier: $showsEarlier)
                    .frame(width: width)
                    .environment(\.boardTitle, BoardCardMetrics.title(item, cardWidth: width - 2 * BoardCardMetrics.inset, typeSize: typeSize))
            }
        }
        #if os(macOS)
        // Mac 的列头那一排就是标题栏那一排：列与列之间空着的那截按住拖窗口。垫在滚动区的内容里：要横滑时按下归滚动区，垫在它后面的接不到（HID 实测）
        .background(alignment: .top) { Color.clear.frame(height: band).windowDragArea() }
        #endif
    }
}

/// 四列各多宽（`BoardColumns`）：等分可见宽，不窄于 `minColumn`。
/// 否决过：按内容分宽（推进中、等你有卡时不低于均分，待办、已完成与空列让宽到 140）——卡一换列整排列宽跟着换档、卡跟着折行，
/// 眼睛要重新找；临界宽也跟着看板另算一份，换页时会话条自己开合。
enum BoardWidths {
    /// 一列最窄（三端同一个）：放得下圈与折几行后够读的标题（`BoardCardMetrics.title`）。四列连同页边放进主区最窄（`WideMetrics.narrowestMain`）；
    /// iPad 竖屏、iPhone 横屏也排得下四列，再窄就整排横滑。
    static let minColumn: CGFloat = 175
    /// 列与列之间：列没有底，相邻两列的卡靠各自离列边的 `BoardCardMetrics.inset` 分开（看着隔 `BoardCardMetrics.columnGap`），不另留缝。
    static let gap = BoardCardMetrics.columnGap - 2 * BoardCardMetrics.inset

    /// 一列多宽；`room` 是可见宽去掉两侧页边。
    static func column(room: CGFloat) -> CGFloat {
        let count = CGFloat(TaskBoard.Column.allCases.count)
        return max(minColumn, (room - gap * (count - 1)) / count)
    }
}

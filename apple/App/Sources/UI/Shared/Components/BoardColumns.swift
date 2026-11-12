import CueStore
import SwiftUI

struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    let margin: CGFloat
    @State private var showsEarlier = DebugHooks.preset.showsDone

    #if os(macOS)
    @Environment(\.boardBand) private var band
    #endif

    var body: some View {
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
            }
        }
        #if os(macOS)
        // Mac 的列头那一排就是标题栏那一排：列与列之间空着的那截按住拖窗口。垫在滚动区的内容里：要横滑时按下归滚动区，垫在它后面的接不到（HID 实测）
        .background(alignment: .top) { Color.clear.frame(height: band).windowDragArea() }
        #endif
    }
}

/// 否决过：按内容分宽（推进中、等你有卡时不低于均分，待办、已完成与空列让宽到 140）——卡一换列整排列宽跟着换档、卡跟着折行，
/// 眼睛要重新找；临界宽也跟着看板另算一份，换页时会话条自己开合。
enum BoardWidths {
    /// 两行够读完一个标题（一行九个汉字上下）、卡脚放得下项目名与读数；四列连同页边放进主区最窄（`WideMetrics.narrowestMain`）。
    static let minColumn: CGFloat = 175
    /// 列与列之间：列没有底，相邻两列的卡靠各自离列边的 `BoardCardMetrics.inset` 分开（看着隔 `BoardCardMetrics.columnGap`），不另留缝。
    static let gap = BoardCardMetrics.columnGap - 2 * BoardCardMetrics.inset

    static func column(room: CGFloat) -> CGFloat {
        let count = CGFloat(TaskBoard.Column.allCases.count)
        return max(minColumn, (room - gap * (count - 1)) / count)
    }
}

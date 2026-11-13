import CueStore
import SwiftUI

struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    let margin: CGFloat
    /// 滚动区右端压在别的东西下面的那一截（宽屏的 Cue 浮板）：列按让出它之后的宽分，放不下横滑时滑进它下面。
    var tail: CGFloat = 0
    @State private var showsEarlier = DebugHooks.preset.showsDone

    #if os(macOS)
    @Environment(\.boardBand) private var band
    #endif

    var body: some View {
        GeometryReader { proxy in
            let room = proxy.size.width - margin * 2 - tail
            // 放得下、放不下都是这一个滚动区（放得下时只是滚不动）：窗口拖过四列最窄时不换结构，列里的滚动位置留着
            ScrollView(.horizontal) { columns(room) }
                .safeAreaPadding(.horizontal, margin)
                .safeAreaPadding(.trailing, tail)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                .boardStage()
        }
    }

    private func columns(_ room: CGFloat) -> some View {
        HStack(alignment: .top, spacing: BoardWidths.gap) {
            ForEach(TaskBoard.Column.allCases, id: \.self) { item in
                BoardColumn(column: item, board: board, adding: $adding, newTaskProject: newTaskProject, earlier: $showsEarlier)
                    .frame(width: BoardWidths.column(item, room: room))
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
    /// Mac 会话条开着、窗口约千点宽时四列放得下，再窄横滑。
    /// iPad 的字与列头的钮大一档：175 放不下「推进中 14」与加号、列名截成"…"（实测横屏、Cue 开着）；两行够读完一个标题（一行九个汉字上下）、卡脚放得下项目名与读数。
    #if os(macOS)
    static let minColumn: CGFloat = 148
    #else
    static let minColumn: CGFloat = 192
    #endif
    /// 列与列之间：列没有底，相邻两列的卡靠各自离列边的 `BoardCardMetrics.inset` 分开（看着隔 `BoardCardMetrics.columnGap`），不另留缝。
    static let gap = BoardCardMetrics.columnGap - 2 * BoardCardMetrics.inset

    /// 按份数分（`TaskBoard.Column.share`）；窄到轻的那两列不足最窄时四列均分，再窄横滑。
    static func column(_ column: TaskBoard.Column, room: CGFloat) -> CGFloat {
        let all = TaskBoard.Column.allCases
        let free = room - gap * CGFloat(all.count - 1), shares = all.reduce(0) { $0 + $1.share }
        guard free * (all.map(\.share).min() ?? 1) / shares >= minColumn else { return max(minColumn, free / CGFloat(all.count)) }
        return (free * column.share / shares).rounded(.down)
    }
}

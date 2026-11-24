import CueStore
import SwiftUI

struct BoardColumns: View {
    let board: TaskBoard
    let margin: CGFloat
    var tail: CGFloat = 0
    @State private var showsEarlier = DebugHooks.args.layoutOpts.showsDone

    #if os(macOS)
    @Environment(\.boardBand) private var band
    #endif

    var body: some View {
        GeometryReader { proxy in
            let room = proxy.size.width - margin * 2 - tail
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
                BoardColumn(column: item, board: board, earlier: $showsEarlier)
                    .frame(width: BoardWidths.column(item, room: room))
            }
        }
        #if os(macOS)
        // Mac 的列头那一排就是标题栏那一排：列与列之间空着的那截按住拖窗口。垫在滚动区的内容里：要横滑时按下归滚动区，垫在它后面的接不到（HID 实测）
        .background(alignment: .top) { Color.clear.frame(height: band).windowDragArea() }
        #endif
    }
}

enum BoardWidths {
    #if os(macOS)
    static let minColumn: CGFloat = 148
    #else
    static let minColumn: CGFloat = 192
    #endif
    static let gap = BoardCardMetrics.columnGap - 2 * BoardCardMetrics.inset

    static func column(_ column: TaskBoard.Column, room: CGFloat) -> CGFloat {
        let all = TaskBoard.Column.allCases
        let free = room - gap * CGFloat(all.count - 1), shares = all.reduce(0) { $0 + $1.share }
        guard free * (all.map(\.share).min() ?? 1) / shares >= minColumn else { return max(minColumn, free / CGFloat(all.count)) }
        return (free * column.share / shares).rounded(.down)
    }
}

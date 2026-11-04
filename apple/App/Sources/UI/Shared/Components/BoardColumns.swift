import CueStore
import SwiftUI

/// 四列并排（Mac、宽屏 iPad 与 iPhone 横屏的进展页）：每列（`BoardColumn`）的列头浮在顶上（`BoardColumnHeader`，写字玻璃），卡各自滚动、从列头后面过。
/// 列宽按内容分（`BoardWidths`）：空列收窄到只放得下列头，卡少的列只给最窄，宽给卡多的列；换了档的那一下跟着看板这一次读到的过渡走
/// （`observingBoard` 的事务：卡换列、列宽一起滑到新处），拖窗口改宽、换项目范围（整块换内容，`TaskBoardPage`）时一步到位。
/// 四列总在眼前，放不下时（如 Mac 窄窗开着侧栏）整排横向滚动、最右一列露出一截（看得出能横划）：两侧页边是滚动区内容的边（`margin`），
/// 列滚到窗口边才裁，滚到头右边照样留页边。卡换列时从原处飞到新处（`boardFlight`），四列共用量飞行位置的坐标系与正被拖着的那件（`boardStage`）。
struct BoardColumns: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    /// 两侧页边。
    let margin: CGFloat
    /// 已完成列末尾"更早做完的"展开着（它展开了已完成就不是空列）。
    @State private var showsEarlier = DebugHooks.preset.showsDone

    /// 四列都取最窄、连同列间与两侧页边要多宽（`WideMetrics` 按它算放不放得下看板）：按卡最多的样子算，临界宽不随卡多卡少变。
    static func narrowest(margin: CGFloat) -> CGFloat { BoardWidths.minColumn * 4 + BoardWidths.gap * 3 + margin * 2 }

    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
    @Environment(\.boardBand) private var band
    #endif

    var body: some View {
        let fills = TaskBoard.Column.allCases.map { BoardWidths.Fill(count: count($0)) }
        // 按可见宽算一次各列宽与卡标题的行数，每列的卡都用这一份（几何读数只给子视图，不写回状态）
        GeometryReader { proxy in
            let widths = BoardWidths.of(fills, room: proxy.size.width - margin * 2)
            // 放得下、放不下都是这一个滚动区（放得下时只是滚不动）：窗口拖过看板最窄宽时不换结构，列里的滚动位置留着
            ScrollView(.horizontal) { columns(widths) }
                .safeAreaPadding(.horizontal, margin)
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                .boardStage()
        }
    }

    private func columns(_ widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: BoardWidths.gap) {
            ForEach(Array(TaskBoard.Column.allCases.enumerated()), id: \.element) { index, item in
                let width = widths[index]
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

    /// 这一列此刻排着几张卡（添加任务那一行、展开的更早做完的都算）。
    private func count(_ column: TaskBoard.Column) -> Int {
        switch column {
        case .todo: board.todo.count + (adding ? 1 : 0)
        case .done: board.done.count + (showsEarlier ? board.earlier.count : 0)
        case .advancing, .waiting: board.count(column)
        }
    }
}

/// 四列各多宽（`BoardColumns`）：按这一列此刻排着几张卡分三档（`Fill`）——
/// - 空的（只有占位那一句）：`compact`，放得下列头（记号、列名、数与"+"）就够，占位那一句在里面折行；空列占一整列宽时，卡多的那几列反而被挤成一行三四个字；
/// - 一两张卡的：最窄 `minColumn`，不分多出来的宽——卡少，竖着有的是地方，标题多折一行也不用滚；
/// - 三张起的：最窄之外按份数（`TaskBoard.Column.share`：推进中、等你多分，待办、已完成少分）分可见宽多出来的。
/// 多出来的宽只给有卡最多的那一档：四列都只有一两张时分给它们，四列全空时照份数分给四列（不全挤在左边、右边空一大片）。
/// 分档按张数、不按标题多长：一张卡的标题变长不让整排改宽，换档只在卡进出这一列时，跟着那一下的过渡走。
enum BoardWidths {
    enum Fill: Int, Comparable {
        case empty, few, full

        init(count: Int) { self = count == 0 ? .empty : count <= BoardWidths.fewCards ? .few : .full }

        static func < (a: Fill, b: Fill) -> Bool { a.rawValue < b.rawValue }
    }

    /// 一列最窄（三端同一个）：放得下圈、项目小图形与折几行后够读的标题（`BoardCardMetrics.title`）。
    /// iPad 竖屏、iPhone 横屏、Mac 900 宽收起侧栏的窗口都排得下四列；900 宽开着侧栏排不下，横滑。
    static let minColumn: CGFloat = 160
    /// 空列：列头（`BoardColumnHeader`）的记号、四个字的列名、数与"+"连同玻璃里外的边刚好放下。
    static let compact: CGFloat = 140
    /// 列与列之间：列没有底，靠这段留白分开。
    static let gap: CGFloat = 20
    /// 几张卡以内算卡少。
    static let fewCards = 2

    /// `room`：可见宽去掉两侧页边。顺序同 `TaskBoard.Column.allCases`。
    static func of(_ fills: [Fill], room: CGFloat) -> [CGFloat] {
        let columns = TaskBoard.Column.allCases
        let base = fills.map { $0 == .empty ? compact : minColumn }
        let spare = max(0, room - gap * CGFloat(columns.count - 1) - base.reduce(0, +))
        let top = fills.max() ?? .empty
        let shares = zip(columns, fills).map { column, fill in fill == top ? column.share : 0 }
        let total = shares.reduce(0, +)
        return zip(base, shares).map { base, share in base + (total > 0 ? spare * share / total : 0) }
    }
}

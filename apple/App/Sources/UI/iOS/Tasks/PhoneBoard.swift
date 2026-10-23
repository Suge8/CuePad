#if os(iOS)
import CueStore
import SwiftUI

/// 原型（proto/phone-board，不进主干）：窄屏任务页的竖屏看板——四列泳道横排成一条，同 Mac 的 board7（`BoardColumn`、`BoardLane`、列头 `BoardLaneMark`）。
/// 列头跟着卡竖着滚，整条泳道从页顶的玻璃与状态栏那一条下面滚过去（`BoardColumn.headerScrolls`）；一屏放不下就横着滑，按列停（`viewAligned`）。页里不再有四个分段。
/// 横拖的归属（`PagerArbiter`）：页中间横滑是看板的，滑到头再拖与贴屏幕左右边起手才是切页。
/// 四列常驻（不用懒加载的横排）：一共四列，懒加载只省得下滑出屏的一两列，换来的是滑回来时重建、竖滚的位置丢掉；列里的卡照样懒加载。
/// 排法按 `-CuePadProtoBoard`：
/// - A「一列半」：一列约八成屏宽，右边露出下一列的列头与卡的开头；卡同 Mac，一行标题。
/// - B「一屏一列、两边露边」：一列占满一屏、居中，左右各露出邻列的一条边；卡最宽。
///   （先试过一屏两列：半屏宽里推进中的标题被状态词挤断成"投…""rel ay"，等你的气泡一行只剩七八个字，放不下，换成这个。）
/// - C「空列收窄」：同 A 的宽，此刻没有卡的列收成一条窄柱（记号、竖排列名、数），点它展开并滑过去（已完成今天还没有、更早做完的收在里面）；待办点了"+"时照常展开。
struct PhoneBoard: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Binding var column: TaskBoard.Column?
    /// C：点开了的窄柱。
    @State private var opened: Set<TaskBoard.Column> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let style = DebugHooks.preset.protoBoard

    static let margin: CGFloat = 12
    /// 列间的空不小于列离屏边的空：停在一列上时前一列整个让出屏外，不在边上留一线。
    static let gap: CGFloat = 12
    static let folded: CGFloat = 52
    /// B：列离屏幕边多远（邻列露出这么宽减去列间的空）。
    static let centered: CGFloat = 26

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(TaskBoard.Column.allCases) { column in
                    lane(column).id(column)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, style == "B" ? Self.centered : Self.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $column, anchor: .leading)
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    @ViewBuilder private func lane(_ column: TaskBoard.Column) -> some View {
        if folds(column) {
            Button {
                // 展开的同时滑到它：点的是这一列，展开后它整个露出来
                withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) {
                    opened.insert(column)
                    self.column = column
                }
            } label: {
                FoldedLane(column: column, count: board.count(column))
            }
            .buttonStyle(PressStyle())
            .frame(width: Self.folded)
            .transition(.opacity)
        } else {
            BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject, headerScrolls: true)
                .containerRelativeFrame(.horizontal) { width, _ in laneWidth(width) }
        }
    }

    /// C：此刻没有卡、也没点开的列（待办正在添加时不算）。
    private func folds(_ column: TaskBoard.Column) -> Bool {
        style == "C" && board.count(column) == 0 && !opened.contains(column) && !(column == .todo && adding)
    }

    private func laneWidth(_ width: CGFloat) -> CGFloat {
        // 容器宽已去掉左右的内容边距
        style == "B" ? width : (width * 0.8).rounded()
    }
}

/// C 里收起的列：一条窄柱，顶上是列头那颗记号与数，下面竖排列名。
private struct FoldedLane: View {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            BoardLaneMark(column: column, size: 20).frame(height: BoardColumnHeader.height)
            VStack(spacing: 2) {
                ForEach(Array(column.title.enumerated()), id: \.offset) { Text(String($1)) }
            }
            .font(.headline).foregroundStyle(palette.ink2)
            Text("\(count)").font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(palette.ink3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BoardLane(column: column, targeted: false) }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(column.title) \(count)")
        .accessibilityHint("展开这一列")
    }
}

#endif

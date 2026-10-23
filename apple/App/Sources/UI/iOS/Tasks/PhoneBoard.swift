#if os(iOS)
import CueStore
import SwiftUI

/// 原型（proto/phone-board，不进主干）：窄屏任务页的竖屏看板——四列泳道横排成一条，同 Mac 的 board7（`BoardColumn`、`BoardLane`、列头 `BoardLaneMark`）。
/// 列头跟着卡竖着滚，整条泳道从页顶的玻璃与状态栏那一条下面滚过去（`BoardColumn.headerScrolls`）；一屏放不下就横着滑，按列停（`viewAligned`）。页里不再有四个分段。
/// 横拖的归属（`PagerArbiter`）：页中间横滑是看板的，滑到头再拖与贴屏幕左右边起手才是切页。
/// 四列常驻（不用懒加载的横排）：一共四列，懒加载只省得下滑出屏的一两列，换来的是滑回来时重建、竖滚的位置丢掉；列里的卡照样懒加载。
/// 排法按 `-CuePadProtoBoard`：
/// - A「一列半」：一列约八成屏宽，右边露出下一列的列头与卡的开头；卡同 Mac，一行标题。
/// - B「一屏两列」：两列各半屏，四列两屏看完；卡收紧成两行标题，等你的卡让出头像那一格（`boardCompact`）。
/// - C「空列收窄」：同 A 的宽，此刻没有卡的列收成一条窄柱（记号、数、竖排列名），点它展开；待办点了"+"、已完成点开看更早的都照常展开。
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
    static let gap: CGFloat = 10
    static let folded: CGFloat = 52

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(TaskBoard.Column.allCases) { column in
                    lane(column).id(column)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $column, anchor: .leading)
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .environment(\.boardCompact, style == "B")
    }

    @ViewBuilder private func lane(_ column: TaskBoard.Column) -> some View {
        if folds(column) {
            Button {
                withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { _ = opened.insert(column) }
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
        switch style {
        case "B": ((width - Self.gap) / 2).rounded(.down)
        default: (width * 0.8).rounded()
        }
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

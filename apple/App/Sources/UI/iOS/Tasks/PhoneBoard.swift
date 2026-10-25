#if os(iOS)
import CueStore
import SwiftUI

/// 窄屏进展页的竖版看板：Mac 看板转 90°——待办、推进中、等你、已完成四行竖着排，每行一条（`BoardRowLane`），
/// 行头竖在左端，卡在行里横着排、放不下就在这一行里横划。
/// 四行竖着铺满顶栏与底部那一排之间（`BoardRows`）：行高只由这段高定，卡多卡少、有没有都不改，下面不空出一块；
/// 矮屏与大字号放不下时各行取最小高（`BoardRowLane` 的最小高），整页竖着滚。
/// 横拖的归属照通用的那条（`PagerArbiter`）：手指下的行还能往那边滚就滚行，贴屏幕边起手、滚到头、行与行之间、空行、行头上的横拖是切页。
/// 点"+"添加任务时整页先回到待办那一行。
struct PhoneBoard: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                BoardRows(gap: Self.gap) {
                    // 量这一屏多高的尺：滚动区看得见的那段（让开顶栏与底部那一排）
                    Color.clear.containerRelativeFrame(.vertical)
                    ForEach(TaskBoard.Column.allCases) { column in
                        BoardColumn(column: column, board: board, adding: $adding, newTaskProject: newTaskProject, row: true)
                            .id(column)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .onChange(of: adding) {
                if adding { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(TaskBoard.Column.todo, anchor: .top) } }
            }
        }
    }

    /// 行与行之间：行没有底，靠这段留白分开。
    static let gap: CGFloat = 12
}

/// 四行竖着铺满一屏：第一个子视图是尺（`containerRelativeFrame` 量出滚动区看得见的高，不占位置），其余是行。
/// 每行先给它的最小高（不给高时它答的理想高：行里的格只定了最矮、往下能伸），剩下的按最小高的比例分给各行；放不下时就是最小高，总高超出一屏、滚动区竖着滚。
/// 一次排版里算完，不经几何读数写回状态（docs/ui.md 布局约束）。
private struct BoardRows: Layout {
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: heights(width: width, subviews: subviews).reduce(0, +) + gaps(subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (row, height) in zip(subviews.dropFirst(), heights(width: bounds.width, subviews: subviews)) {
            row.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + gap
        }
        subviews.first?.place(at: bounds.origin, proposal: .zero)
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { gap * CGFloat(max(subviews.count - 2, 0)) }

    private func heights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        guard let ruler = subviews.first else { return [] }
        let screen = ruler.sizeThatFits(.unspecified).height
        let least = subviews.dropFirst().map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let total = least.reduce(0, +)
        let scale = total > 0 ? max(1, (screen - gaps(subviews)) / total) : 1
        return least.map { ($0 * scale).rounded(.down) }
    }
}
#endif

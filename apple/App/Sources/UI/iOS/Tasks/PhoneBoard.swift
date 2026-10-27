#if os(iOS)
import CueStore
import SwiftUI

/// 窄屏进展页的竖版看板：Mac 看板转 90°——待办、推进中、等你、已完成四行竖着排，每行一条（`BoardRowLane`），
/// 行头竖在左端，卡在行里横着排、放不下就在这一行里横划。
/// 四行竖着铺满顶栏与底部那一排之间（`BoardRows`）：行高只由这段高定，卡多卡少、有没有都不改，下面不空出一块，整页拖不动；
/// 只有辅助字号下四行连各自的最矮都叠不下，才整页竖着滚。高按各行的理想高分（`TaskBoard.Column.rowTiers`）：推进中、等你各三排卡，
/// 待办、已完成各一排矮卡——iPhone 17 默认字号下推进中的三排还余约 14 点、等你约 11 点（实测于底部那一排之上），矮屏与大一两档的字下重的两行先回到两排。
/// 卡换行时从原处飞到新处（`boardFlight`），四行共用一个飞行的命名空间与正被拖着的那件（`boardStage`）。
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
            .boardStage()
            .onChange(of: adding) {
                if adding { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(TaskBoard.Column.todo, anchor: .top) } }
            }
        }
    }

    /// 行与行之间：行没有底，靠这段留白分开。
    static let gap: CGFloat = 12
}

/// 四行竖着铺满一屏：第一个子视图是尺（`containerRelativeFrame` 量出滚动区看得见的高，不占位置），其余是行。
/// 每行答两个高（`BoardRowLane`）：理想高（不给高时）与最矮（给零高时）。放得下理想高时多出来的按理想高的比例分给各行；
/// 放不下时各行从理想高往最矮收，按各自能收的那截分摊，总高仍正好一屏——超出一点点整页就能上下拖（矮屏、大一两档的字）。
/// 连最矮都叠不下（辅助字号）才取最矮、滚动区竖着滚。一次排版里算完，不经几何读数写回状态（docs/ui.md 布局约束）。
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
        let room = ruler.sizeThatFits(.unspecified).height - gaps(subviews)
        let rows = subviews.dropFirst()
        let ideal = rows.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let least = rows.map { $0.sizeThatFits(ProposedViewSize(width: width, height: 0)).height }
        let wanted = ideal.reduce(0, +), tightest = least.reduce(0, +)
        let heights: [CGFloat] = if room >= wanted {
            ideal.map { $0 * room / wanted }
        } else if room > tightest {
            zip(ideal, least).map { $1 + ($0 - $1) * (room - tightest) / (wanted - tightest) }
        } else {
            least
        }
        return heights.map { $0.rounded(.down) }
    }
}
#endif

#if os(iOS)
import CueStore
import SwiftUI

struct PhoneBoard: View {
    let board: TaskBoard
    @Binding var adding: Bool
    let newTaskProject: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                BoardRows(gap: Self.gap) {
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
                if adding { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { proxy.scrollTo(TaskBoard.Column.todo, anchor: .top) } }
            }
        }
    }

    /// 行头离上一行远、离自己的卡近。
    static let gap = Spacing.item
}

/// 一次排版里算完，不经几何读数写回状态：写回影响自身排版的状态会形成布局反馈环。
/// 各行按自己的高排，一屏放不下就上下滚；有余高时整排整排地分给还有卡没露出来的行（`BoardRowFlex`，先后见 `BoardRowLane`），
/// 卡不拉高，剩的零头留在页尾。
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
        let rows = Array(subviews.dropFirst())
        var heights = rows.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        var spare = ruler.sizeThatFits(.unspecified).height - heights.reduce(0, +) - gaps(subviews)
        let flexible = rows.indices.compactMap { index in rows[index][BoardRowFlex.self].map { (index, $0) } }.sorted { $0.1.rank < $1.1.rank }
        for (index, flex) in flexible {
            let more = CGFloat(min(flex.most - 1, max(0, Int(spare / flex.step)))) * flex.step
            heights[index] += more
            spare -= more
        }
        return heights
    }
}
#endif

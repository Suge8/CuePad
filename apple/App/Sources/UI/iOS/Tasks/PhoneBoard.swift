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

    static let gap: CGFloat = 12
}

/// 一次排版里算完，不经几何读数写回状态：写回影响自身排版的状态会形成布局反馈环。
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

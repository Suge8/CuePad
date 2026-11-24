#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var boardBand: CGFloat = 0
}

extension View {
    func boardTopRow(column: TaskBoard.Column, count: Int, archives: Bool, targeted: Bool) -> some View {
        modifier(BoardTopRow(column: column, count: count, archives: archives, targeted: targeted))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    let archives: Bool
    let targeted: Bool
    @Environment(\.boardBand) private var band
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
            .background { BoardLane(targeted: targeted).padding(.top, band + Bars.contentGap).padding(.bottom, BoardCardMetrics.inset) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count, archives: archives)
            .padding(.horizontal, TaskMetrics.cardPadding)
            .glass(in: .capsule)
            .padding(.horizontal, BoardCardMetrics.inset)
    }
}
#endif

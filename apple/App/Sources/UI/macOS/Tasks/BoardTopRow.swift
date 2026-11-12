#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 否决过胶囊：一排四颗带大数字的胶囊读作状态胶囊、压过下面的卡。
    func boardTopRow(column: TaskBoard.Column, count: Int, archives: Bool) -> some View {
        modifier(BoardTopRow(column: column, count: count, archives: archives))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    let archives: Bool
    @Environment(\.boardBand) private var band
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count, archives: archives)
            .padding(.horizontal, Self.inner)
            .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
            .padding(.leading, BoardCardMetrics.inset)
            .padding(.trailing, BoardCardMetrics.inset)
    }

    private static let inner = TaskMetrics.cardPadding

}
#endif

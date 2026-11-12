#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头只是字，身后垫一条桌面色：卡从它后面滚过去时不透上来。否决过胶囊与玻璃底：一排四个框压过下面的卡。
    func boardTopRow(column: TaskBoard.Column, count: Int) -> some View {
        modifier(BoardTopRow(column: column, count: count))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.boardBand) private var band
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count)
            .padding(.horizontal, Self.inner + BoardCardMetrics.inset)
            .frame(maxHeight: .infinity)
            .background(palette.desk)
    }

    private static let inner = TaskMetrics.cardPadding

}
#endif

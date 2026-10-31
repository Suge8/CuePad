#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 看板列头占据的高度。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头在各自的列内，卡片从玻璃后滚过。
    func boardTopRow(column: TaskBoard.Column, count: Int) -> some View {
        modifier(BoardTopRow(column: column, count: count))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.boardBand) private var band
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count)
            .padding(.horizontal, Self.inner)
            .glass(in: .capsule)
            .padding(.leading, BoardCardMetrics.inset)
            .padding(.trailing, BoardCardMetrics.inset)
    }

    /// 玻璃里字离两头多远：卡里的字也这么远，列头的记号与卡上的对齐。
    private static let inner = TaskMetrics.cardPadding

}
#endif

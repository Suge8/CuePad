#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 看板列头那一排的高：就是窗口最顶那一排（`Chrome.band`），列头与红绿灯、栏头的钮同一条中线。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头在各自的列内、排在窗口最顶那一排，卡片从玻璃后滚过。玻璃同卡一样宽、一样的圆角（`TaskMetrics.cardRadius`），读作这一列的盖子；
    /// 高同这一排别的钮（`Chrome.control`）。否决过胶囊：一排四颗带大数字的胶囊读作状态胶囊、压过下面的卡。
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
            .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
            .padding(.leading, BoardCardMetrics.inset)
            .padding(.trailing, BoardCardMetrics.inset)
    }

    /// 玻璃里字离两头多远：卡里的字也这么远，列头的记号与卡上的对齐。
    private static let inner = TaskMetrics.cardPadding

}
#endif

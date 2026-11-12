#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头只是字，身后垫一条桌面色：卡从它后面滚过去时不透上来。否决过胶囊与玻璃底：一排四个框压过下面的卡。
    /// `targeted`：拖着的卡在这一列上，卡身后亮一块圆角的底——从列头下面起、离窗口下沿留一截，四角都看得见（铺满整列的话上沿被列头切平、下沿贴着窗口，是一块直角的矩形）。
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
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
            .background { BoardLane(targeted: targeted).padding(.top, band + Bars.contentGap).padding(.bottom, BoardCardMetrics.inset) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count, archives: archives)
            .padding(.horizontal, Self.inner + BoardCardMetrics.inset)
            .frame(maxHeight: .infinity)
            .background(palette.desk)
    }

    private static let inner = TaskMetrics.cardPadding

}
#endif

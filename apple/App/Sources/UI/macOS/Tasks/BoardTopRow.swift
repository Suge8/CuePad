#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头是一块写字玻璃，与卡同宽（同 iPad）：卡从它后面滚过。只是字、身后垫桌面色的那一版试过：四列都是白卡之后，一排裸字压不住下面的卡。
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
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
            .background { BoardLane(targeted: targeted).padding(.top, band + Bars.contentGap).padding(.bottom, BoardCardMetrics.inset) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count, archives: archives)
            .padding(.horizontal, TaskMetrics.cardPadding)
            .glass(in: .rect(cornerRadius: TaskMetrics.cardRadius))
            .padding(.horizontal, BoardCardMetrics.inset)
    }
}
#endif

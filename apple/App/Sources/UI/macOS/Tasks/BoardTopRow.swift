#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 窗口最顶那一排（红绿灯与工具栏）有多高：任务页的列头排在这一排里（`TaskBoardPage` 量，`boardTopRow` 用）。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 一列的列头排进窗口最顶那一排、卡从它下面滚过（docs/ui.md 沉浸式的栏）：这一列自己在那一排垫页底色的渐变（`TopFade`，
    /// 同主窗口的 `ToolbarFade`，任务页上那一条由各列自己垫，列头才压得在渐变上面），列头是写在渐变上的字，不另垫玻璃（同访达的列头：四块玻璃排一行读起来像四颗钮）。最右那一列的列头给右上的"⋯"让出一截。
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
            .overlay(alignment: .top) {
                ZStack {
                    TopFade(color: palette.desk).frame(height: band + Bars.contentGap, alignment: .top)
                    header.frame(height: band).frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(height: band + Bars.contentGap)
            }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count)
            .padding(.leading, TaskMetrics.cardPadding + BoardCardMetrics.inset)
            .padding(.trailing, TaskMetrics.cardPadding + BoardCardMetrics.inset + (column == .done ? Self.moreReserve : 0))
    }

    /// "⋯"（`PageMenuSlot`）的左沿比最右那一列的列头右沿往里这么多，再空 8：工具栏离窗口右边 4、钮宽 `toolbarControl`，列离窗口右边 `Spacing.page`。
    private static let moreReserve = 4 + Spacing.toolbarControl + 8 - Spacing.page
}
#endif

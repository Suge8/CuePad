#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 窗口最顶那一排（红绿灯与工具栏）有多高：进展页的列头排在这一排里（`TaskBoardPage` 量，`boardTopRow` 用）。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 一列的列头排进窗口最顶那一排、卡从它下面滚过（docs/ui.md 沉浸式的栏）：这一列自己在那一排垫页底色的渐变（`TopFade`，
    /// 同主窗口的 `ToolbarFade`，进展页上那一条由各列自己垫，列头才压得在渐变上面），列头是写在渐变上的字，不另垫玻璃（同访达的列头：四块玻璃排一行读起来像四颗钮）。最右那一列的列头给右上的"⋯"让出一截，待办的列头给左上的两段分段让出一截。
    func boardTopRow(column: TaskBoard.Column, count: Int) -> some View {
        modifier(BoardTopRow(column: column, count: count))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.boardBand) private var band
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 这一列的左沿在窗口里的横坐标（只有待办量：它让出左上的分段）。
    @State private var left: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat?.self) { column == .todo ? $0.frame(in: .global).minX : nil } action: { left = $0 }
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
            .padding(.leading, max(Self.lead, panesReserve))
            .padding(.trailing, TaskMetrics.cardPadding + BoardCardMetrics.inset + (column == .done ? Self.moreReserve : 0))
    }

    private static let lead = TaskMetrics.cardPadding + BoardCardMetrics.inset

    /// 待办的列头从左上分段（`PanesSlot`）的右沿再空 `panesGap` 起；分段在不在这一列上方随侧栏开合、拖宽而变，按量到的算。
    private var panesReserve: CGFloat {
        guard let left, workspace.pages.panesEdge > 0 else { return 0 }
        return workspace.pages.panesEdge + Self.panesGap - left
    }

    private static let panesGap: CGFloat = 12

    /// "⋯"（`PageMenuSlot`）的左沿比最右那一列的列头右沿往里这么多，再空 8：工具栏离窗口右边 4、钮宽 `toolbarControl`，列离窗口右边 `Spacing.page`。
    private static let moreReserve = 4 + Spacing.toolbarControl + 8 - Spacing.page
}
#endif

#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 窗口最顶那一排（红绿灯与工具栏）有多高：进展页的列头排在这一排里（`TaskBoardPage` 量，`boardTopRow` 用）。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 一列的列头排进窗口最顶那一排、卡从它下面滚过（docs/ui.md 沉浸式的栏，那一排什么都不垫）：列头是一块写字玻璃，与那一排的分段、"⋯"同高同一条中线（同 iPad 的列头）。
    /// 否决过：只写字、不垫玻璃（同访达的列头），那一排不垫渐变后卡滚上来就压在字上。最右那一列的列头给右上的"⋯"让出一截，待办的列头给左上的两段分段让出一截。
    func boardTopRow(column: TaskBoard.Column, count: Int) -> some View {
        modifier(BoardTopRow(column: column, count: count))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.boardBand) private var band
    @Environment(Workspace.self) private var workspace
    /// 这一列的左沿在窗口里的横坐标（只有待办量：它让出左上的分段）。
    @State private var left: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat?.self) { column == .todo ? $0.frame(in: .global).minX : nil } action: { left = $0 }
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count)
            .padding(.horizontal, Self.inner)
            .glass(in: .capsule)
            .padding(.leading, max(BoardCardMetrics.inset, panesReserve))
            .padding(.trailing, BoardCardMetrics.inset + (column == .done ? Self.moreReserve : 0))
    }

    /// 玻璃里字离两头多远：卡里的字也这么远，列头的记号与卡上的对齐。
    private static let inner = TaskMetrics.cardPadding

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

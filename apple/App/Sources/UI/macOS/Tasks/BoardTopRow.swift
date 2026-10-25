#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 窗口最顶那一排（红绿灯与工具栏）有多高：进展页的列头排在这一排里（`TaskBoardPage` 量，`boardTopRow` 用）。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 一列的列头排进窗口最顶那一排、卡从它下面滚过（docs/ui.md 沉浸式的栏，那一排什么都不垫）：列头是一块写字玻璃，与那一排的分段、"⋯"同高同一条中线（同 iPad 的列头）。
    /// 否决过：只写字、不垫玻璃（同访达的列头），那一排不垫渐变后卡滚上来就压在字上。压在左上分段、右上"⋯"下面的列头给它们让出一截（窄窗口里"⋯"下面是哪一列不定）。
    func boardTopRow(column: TaskBoard.Column, count: Int) -> some View {
        modifier(BoardTopRow(column: column, count: count))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    @Environment(\.boardBand) private var band
    @Environment(Workspace.self) private var workspace
    /// 这一列在窗口里的左右沿。
    @State private var span: ClosedRange<CGFloat>?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: ClosedRange<CGFloat>.self) { $0.frame(in: .global).minX...$0.frame(in: .global).maxX } action: { span = $0 }
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        BoardColumnHeader(column: column, count: count)
            .padding(.horizontal, Self.inner)
            .glass(in: .capsule)
            .padding(.leading, max(BoardCardMetrics.inset, panesReserve))
            .padding(.trailing, max(BoardCardMetrics.inset, moreReserve))
    }

    /// 玻璃里字离两头多远：卡里的字也这么远，列头的记号与卡上的对齐。
    private static let inner = TaskMetrics.cardPadding

    /// 从左上分段（`PanesSlot`）的右沿再空 `panesGap` 起；分段在哪一列上方随侧栏开合、拖宽而变，按量到的算。
    private var panesReserve: CGFloat {
        guard let span, workspace.pages.panesEdge > 0 else { return 0 }
        return workspace.pages.panesEdge + Self.panesGap - span.lowerBound
    }

    private static let panesGap: CGFloat = 12

    /// 到右上"⋯"（`PageMenuSlot`）的左沿前 `moreGap` 止。
    private var moreReserve: CGFloat {
        guard let span, workspace.pages.moreEdge > 0 else { return 0 }
        return span.upperBound - (workspace.pages.moreEdge - Self.moreGap)
    }

    private static let moreGap: CGFloat = 8
}
#endif

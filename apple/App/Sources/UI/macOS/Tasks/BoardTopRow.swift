#if os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// 看板列头那一排的高：就是窗口最顶那一排（`WideMetrics.band`），列头与红绿灯、栏头的钮同一条中线。
    @Entry var boardBand: CGFloat = 0
}

extension View {
    /// 列头在各自的列内、排在窗口最顶那一排，卡片从玻璃后滚过。`add` 是待办列头的 ＋（添加任务）。
    func boardTopRow(column: TaskBoard.Column, count: Int, add: (() -> Void)?) -> some View {
        modifier(BoardTopRow(column: column, count: count, add: add))
    }
}

private struct BoardTopRow: ViewModifier {
    let column: TaskBoard.Column
    let count: Int
    let add: (() -> Void)?
    @Environment(\.boardBand) private var band
    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.top, band + Bars.contentGap)
            .overlay(alignment: .top) { header.frame(height: band) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            BoardColumnHeader(column: column, count: count)
            if let add { BoardAddTask(action: add) }
        }
            .padding(.horizontal, Self.inner)
            .glass(in: .capsule)
            .padding(.leading, BoardCardMetrics.inset)
            .padding(.trailing, BoardCardMetrics.inset)
    }

    /// 玻璃里字离两头多远：卡里的字也这么远，列头的记号与卡上的对齐。
    private static let inner = TaskMetrics.cardPadding

}
#endif

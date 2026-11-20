import SwiftUI

/// 一列滚到哪按卡记，不按偏移量：列宽一变（会话条换宽、Cue 收起放回、拖窗口跨阈值），标题重新折行、整列内容变高变矮，
/// 按偏移量留着的话原来看着的那张卡滑出视野。这里记下可视区正中的那张卡（`scrollTargetLayout` 的直接子视图，即各列 `ForEach` 的身份），
/// 内容一变由滚动视图自己把它留在正中（系统的 `scrollPosition`，不读几何回写）。身份的类型随列：待办、已完成是任务（`TaskBoard.Item.id`），
/// 推进中、等你是会话与任务混排的那一份（`AdvancingSlot.id`、`TaskBoard.Held.id`）。
struct LaneAnchor: ViewModifier {
    let column: TaskBoard.Column
    @State private var position: ScrollPosition
    @State private var span = Span()
    @Environment(\.boardMoves) private var moves

    /// 滚到哪了、能滚到哪：滚动时每帧记，不触发重绘。
    private final class Span {
        var at = CGPoint.zero
        var end: CGFloat = 0
    }

    /// 拖着卡停在列的上下边时每帧滚这么多（一秒六百来点：看得清滚过了什么）。
    private static let step: CGFloat = 10

    init(_ column: TaskBoard.Column) {
        self.column = column
        _position = State(initialValue: column.light ? ScrollPosition(idType: UUID.self) : ScrollPosition(idType: String.self))
    }

    func body(content: Content) -> some View {
        let pull = moves?.pull.flatMap { $0.column == column ? $0.edge : nil }
        content
            .scrollPosition($position, anchor: .center)
            .onScrollGeometryChange(for: [CGFloat].self) {
                // 从内容的起点算，不是滚动视图的偏移量：`scrollTo(point:)` 认的是前者，列头占的那段顶边距不算在内。照偏移量给的话一步都滚不动（实测）
                [$0.contentOffset.x + $0.contentInsets.leading, $0.contentOffset.y + $0.contentInsets.top,
                 max($0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height, 0)]
            } action: { _, now in
                span.at = CGPoint(x: now[0], y: now[1])
                span.end = now[2]
            }
            .task(id: pull) {
                guard pull == .top || pull == .bottom else { return }
                while (try? await Task.sleep(for: .milliseconds(16))) != nil {
                    let next = min(max(span.at.y + (pull == .bottom ? Self.step : -Self.step), 0), span.end)
                    guard next != span.at.y else { continue }
                    position.scrollTo(point: CGPoint(x: span.at.x, y: next))
                    moves?.reaim()
                }
            }
    }
}

import SwiftUI

extension View {
    /// 看板四列（`BoardColumns`）或四行（`PhoneBoard`）的容器：卡飞行量位置的坐标系（`boardFlight`）与正被拖着的那件（`cardDragStage`）。
    func boardStage() -> some View { coordinateSpace(.named(BoardMoves.space)).cardDragStage() }

    /// 看板上能拖的卡（拖到推进中是开始、拖到已完成是做完、待办里拖到别的卡前面是排序，`BoardColumn.drop`）。
    /// 落点的高亮（列的选中底、插入线）只在有卡正被拖着时画（`CardDrags`）。
    func boardDraggable(_ id: UUID) -> some View { cardDraggable(.task(id), shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    /// 待办里一张卡的落点：拖到它上面就是排到它前面，卡的上沿画一条插入线（`InsertionMark`）；拖的就是它自己时不画。
    func insertsBefore(_ id: UUID, perform: @escaping (UUID) -> Void) -> some View { modifier(InsertBefore(id: id, perform: perform)) }
}

private struct InsertBefore: ViewModifier {
    let id: UUID
    let perform: (UUID) -> Void
    @State private var targeted = false
    @Environment(\.cardDrags) private var drags

    func body(content: Content) -> some View {
        let dragging = drags?.current?.task
        let shown = targeted && dragging != nil && dragging != id
        content
            .overlay(alignment: .top) {
                if shown { InsertionMark().offset(y: -8).allowsHitTesting(false).transition(.opacity) }
            }
            .cardDrop(hover: { targeted = $0 != nil }) { card, _ in
                if let task = card.task { perform(task) }
            }
            .animation(Motion.fade, value: shown)
            .sensoryFeedback(.selection, trigger: shown) { _, now in now }
    }
}

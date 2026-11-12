import SwiftUI

extension View {
    func boardStage() -> some View { coordinateSpace(.named(BoardMoves.space)).cardDragStage() }

    func boardDraggable(_ id: UUID, session: String? = nil) -> some View { cardDraggable(.task(id), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    func boardDraggable(session: String) -> some View { cardDraggable(.session(session), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    /// `lands`：拖着的这张放在这里会不会落在这张卡前面；不会就不画线（放下也不挪）。`over`：指针在不在这张卡上。
    func insertsBefore(_ id: UUID, lands: @escaping (UUID) -> Bool, over: @escaping (Bool) -> Void, perform: @escaping (UUID) -> Void) -> some View {
        modifier(InsertBefore(id: id, lands: lands, over: over, perform: perform))
    }
}

private struct InsertBefore: ViewModifier {
    let id: UUID
    let lands: (UUID) -> Bool
    let over: (Bool) -> Void
    let perform: (UUID) -> Void
    @State private var targeted = false
    @Environment(\.cardDrags) private var drags

    func body(content: Content) -> some View {
        let shown = targeted && (drags?.current?.task).map(lands) == true
        content
            .overlay(alignment: .top) {
                if shown { InsertionMark().offset(y: -8).allowsHitTesting(false).transition(.opacity) }
            }
            .cardDrop(hover: { targeted = $0 != nil; over(targeted) }) { card, _ in
                if let task = card.task { perform(task) }
            }
            .animation(Motion.fade, value: shown)
            .sensoryFeedback(.selection, trigger: shown) { _, now in now }
    }
}

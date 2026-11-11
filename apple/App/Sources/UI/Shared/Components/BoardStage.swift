import SwiftUI

extension View {
    func boardStage() -> some View { coordinateSpace(.named(BoardMoves.space)).cardDragStage() }

    func boardDraggable(_ id: UUID, session: String? = nil) -> some View { cardDraggable(.task(id), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    func boardDraggable(session: String) -> some View { cardDraggable(.session(session), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

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

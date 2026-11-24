import SwiftUI

extension View {
    func boardStage() -> some View { modifier(BoardStage()) }

    func boardDraggable(_ id: UUID, session: String? = nil) -> some View { cardDraggable(.task(id), session: session, shape: .rect(cornerRadius: Radius.card)) }

    func boardDraggable(session: String) -> some View { cardDraggable(.session(session), session: session, shape: .rect(cornerRadius: Radius.card)) }
}

private struct BoardStage: ViewModifier {
    @Environment(\.boardMoves) private var moves
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay { BoardFloat() }
            .coordinateSpace(.named(BoardMoves.space))
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { moves?.origin = $0 }
            .onChange(of: reduceMotion, initial: true) { moves?.reduceMotion = reduceMotion }
            .cardDragStage()
    }
}

import SwiftUI

extension View {
    func boardStage() -> some View { coordinateSpace(.named(BoardMoves.space)).cardDragStage() }

    func boardDraggable(_ id: UUID, session: String? = nil) -> some View { cardDraggable(.task(id), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    func boardDraggable(session: String) -> some View { cardDraggable(.session(session), session: session, shape: .rect(cornerRadius: TaskMetrics.cardRadius)) }

    /// 待办的卡报自己在列里的位置，只在拖着时报：平时滚动不写状态。
    func boardSlot(_ id: UUID, in space: String, frames: Binding<[UUID: CGRect]>) -> some View { modifier(BoardSlotFrame(id: id, space: space, frames: frames)) }
}

private struct BoardSlotFrame: ViewModifier {
    let id: UUID
    let space: String
    @Binding var frames: [UUID: CGRect]
    @Environment(\.cardDrags) private var drags

    // 量的那层拖起来才放进去：新放进去的视图一定报一次位置；挂在卡上、只换闭包里的开关的话，卡没动就不报
    func body(content: Content) -> some View {
        content.background {
            if drags?.current?.task != nil {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[id] = $0 }
                    .onDisappear { frames[id] = nil }
            }
        }
    }
}

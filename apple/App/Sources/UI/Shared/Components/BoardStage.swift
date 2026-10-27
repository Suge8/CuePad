import SwiftUI

extension EnvironmentValues {
    /// 正被拖着的那件任务（`boardDraggable` 写，看板的落点读）：nil 是没在拖。
    @Entry var boardDrag: UUID?
    /// 写 `boardDrag` 的那一头（只给 `boardDraggable`）。
    @Entry var boardDragging: Binding<UUID?> = .constant(nil)
}

extension View {
    /// 看板四列（`BoardColumns`）或四行（`PhoneBoard`）的容器：卡飞行量位置的坐标系（`boardFlight`）与正被拖着的那件（`boardDrag`）。
    func boardStage() -> some View { modifier(BoardStage()) }

    /// 看板上能拖的卡（拖到推进中是开始、拖到已完成是做完、待办里拖到别的卡前面是排序，`BoardColumn.drop`）：拖着时记下是哪件，拖完（放下或取消）清掉。
    /// 落点的高亮（列的选中底、插入线）只在有卡正被拖着时画：只靠落点自己的"拖进来了"，拖到别处放下或取消时它可能收不到"拖走了"，
    /// 线与底就一直留在那（手机上像卡片之间插了一条横向滑动条）。拖的开始与结束由拖的那一头报，放在哪、取消都一定收得到。
    func boardDraggable(_ id: UUID) -> some View { modifier(BoardDraggable(id: id)) }

    /// 待办里一张卡的落点：拖到它上面就是排到它前面，卡的上沿画一条插入线（同大纲的插入线：墨色、起点一个小圈）；拖的就是它自己时不画。
    func insertsBefore(_ id: UUID, perform: @escaping ([String]) -> Bool) -> some View { modifier(InsertBefore(id: id, perform: perform)) }
}

private struct BoardStage: ViewModifier {
    @State private var dragging: UUID?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(BoardMoves.space))
            .environment(\.boardDrag, dragging)
            .environment(\.boardDragging, $dragging)
    }
}

private struct BoardDraggable: ViewModifier {
    let id: UUID
    @Environment(\.boardDragging) private var dragging

    func body(content: Content) -> some View {
        content
            .draggable(id.uuidString)
            .onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active: dragging.wrappedValue = id
                default: if dragging.wrappedValue == id { dragging.wrappedValue = nil }
                }
            }
    }
}

private struct InsertBefore: ViewModifier {
    let id: UUID
    let perform: ([String]) -> Bool
    @State private var targeted = false
    @Environment(\.boardDrag) private var dragging
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        let shown = targeted && dragging != nil && dragging != id
        content
            .overlay(alignment: .top) {
                if shown {
                    HStack(spacing: 0) {
                        Circle().strokeBorder(palette.ink, lineWidth: 2).frame(width: 9, height: 9)
                        Capsule().fill(palette.ink).frame(height: 2)
                    }
                    .offset(y: -8).allowsHitTesting(false).transition(.opacity)
                }
            }
            .dropDestination(for: String.self) { ids, _ in perform(ids) } isTargeted: { targeted = $0 }
            .animation(Motion.fade, value: shown)
            .sensoryFeedback(.selection, trigger: shown) { _, now in now }
    }
}

import CueStore
import SwiftUI

extension EnvironmentValues {
    /// 看板卡飞行的命名空间：四列或四行共用一个（`boardStage`），卡换列时两头认得出是同一张。
    @Entry var boardFlight: Namespace.ID?
    /// 这一次读看板换了列的卡（`TaskBoard.moved(from:)`，`observingBoard` 与看板同一个事务里给）。
    @Entry var boardMoved: Set<String> = []
}

extension View {
    /// 看板上一张卡的身份（`TaskBoard.Item.flight`、`Work.id`、`Held.id`：任务是 `task/…`，没绑任务的会话是 `session/…`，换列不换）。
    /// 卡换列是这一列删一张、那一列添一张：两张同一个身份，在同一个动画事务里（`observingBoard`）新的一张从旧的那一处飞到新处，整张不透明地飞，
    /// 旧的那张当场撤掉（只留一张在飞）。新来的（新建、等你来了）在原处淡入；走掉的当场撤掉，列里后面的卡挪上来补位，看得出少了哪张。
    /// 否决过：撤掉的那张也淡出——懒加载栈里带着飞行身份淡出的那张先跳到栈顶再飞，一闪；按"这次是不是换列"给它挑撤法也做不到：
    /// 撤掉时用的是它上一次排版时的样子，那时还不知道它要走。
    /// 飞行要越过所在列、行的边，所以列与行的滚动区不裁内容（`scrollClipDisabled`；超出窗口的照样被窗口裁掉）。
    func boardFlight(_ id: String) -> some View { modifier(BoardFlight(id: id)) }
}

private struct BoardFlight: ViewModifier {
    let id: String
    @Environment(\.boardFlight) private var space
    @Environment(\.boardMoved) private var moved

    func body(content: Content) -> some View {
        if let space {
            content.matchedGeometryEffect(id: id, in: space)
                .transition(.asymmetric(insertion: moved.contains(id) ? .identity : .opacity, removal: .identity))
        } else {
            content
        }
    }
}

extension View {
    /// 读看板（三端进展页同一处）：库变了重读；过了零点也重读一次——"今天做完"按读的那一刻分，库没变时日子换了也要换（同项目页）。
    /// 看板怎么动只在这里定：第一份是页面打开的样子、不动；之后每一份都在一个动画事务里换上（`Motion.move`，减弱动态效果时直接到终态），
    /// 卡的出现、消失、列内让位与换列（`boardFlight`）都跟着这一份走，各列各行不另挂动画。
    func observingBoard(into board: Binding<TaskBoard?>, store: CueStore, onError: @escaping (any Error) -> Void) -> some View {
        modifier(BoardReading(board: board, store: store, onError: onError))
    }
}

private struct BoardReading: ViewModifier {
    @Binding var board: TaskBoard?
    let store: CueStore
    let onError: (any Error) -> Void
    @State private var day = 0
    @State private var moved: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.boardMoved, moved)
            .observing(store, id: day, into: Binding { board } set: { read in
                guard let board, let read else { return board = read }
                withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) {
                    moved = read.moved(from: board)
                    self.board = read
                }
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onDayChange { day += 1 }
    }
}

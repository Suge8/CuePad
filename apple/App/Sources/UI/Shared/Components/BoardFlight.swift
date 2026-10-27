import CueStore
import SwiftUI

extension EnvironmentValues {
    /// 看板卡飞行的命名空间：四列或四行共用一个（`boardStage`），卡换列时两头认得出是同一张。
    @Entry var boardFlight: Namespace.ID?
    /// 这一次读看板换了列的卡（`TaskBoard.moved(from:)`，`observingBoard` 与看板同一个事务里给）。
    @Entry var boardMoved: Set<String> = []
    /// 下一份看板里要换列的卡，在换上那一份之前先给（`observingBoard`）：它们在原处的那张撤掉时不淡出。
    @Entry var boardLeaving: Set<String> = []
}

extension View {
    /// 看板上一张卡的身份（`TaskBoard.Item.flight`、`Work.id`、`Held.id`：任务是 `task/…`，没绑任务的会话是 `session/…`，换列不换）。
    /// 卡换列是这一列删一张、那一列添一张：两张同一个身份，在同一个动画事务里（`observingBoard`）新的一张从旧的那一处飞到新处，整张不透明地飞，
    /// 旧的那张当场撤掉（只留一张在飞）。新来的（新建、取回归档、等你来了）在原处淡入；离开看板的（归档、删掉、等你答完）在原处淡出，列里后面的卡挪上来补位。
    /// 换列的那张要当场撤，是因为懒加载栈里带着飞行身份淡出的那张先跳到栈顶再飞，一闪；撤掉时用的是它上一次排版时的样子，
    /// 所以读看板那一处先单独排一次、告诉它要走（`boardLeaving`），再换上新的一份。
    /// 飞行要越过所在列、行的边，所以列与行的滚动区不裁内容（`scrollClipDisabled`；超出窗口的照样被窗口裁掉）。
    func boardFlight(_ id: String) -> some View { modifier(BoardFlight(id: id)) }
}

private struct BoardFlight: ViewModifier {
    let id: String
    @Environment(\.boardFlight) private var space
    @Environment(\.boardMoved) private var moved
    @Environment(\.boardLeaving) private var leaving

    func body(content: Content) -> some View {
        if let space {
            content.matchedGeometryEffect(id: id, in: space)
                .transition(.asymmetric(insertion: moved.contains(id) ? .identity : .opacity, removal: leaving.contains(id) ? .identity : .opacity))
        } else {
            content
        }
    }
}

extension View {
    /// 读看板（三端进展页同一处）：库变了重读；过了零点也重读一次——"今天做完"按读的那一刻分，库没变时日子换了也要换（同项目页）。
    /// 看板怎么动只在这里定：第一份是页面打开的样子、不动；之后每一份都在一个动画事务里换上（`Motion.move`，减弱动态效果时直接到终态），
    /// 卡的出现、消失、列内让位与换列（`boardFlight`）都跟着这一份走，各列各行不另挂动画。有卡换列时分两步：先只排一次、标出要换列的卡
    /// （`boardLeaving`），排完（`onChange`）再换上新的一份。
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
    @State private var leaving: Set<String> = []
    /// 有卡换列时等着换上的那一份（先排一次 `leaving`）。
    @State private var pending: TaskBoard?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.boardMoved, moved)
            .environment(\.boardLeaving, leaving)
            .observing(store, id: day, into: Binding { board } set: { read in
                guard let board, let read else { return board = read }
                let moving = read.moved(from: board)
                // 没有换列的这一份不清掉还在飞的那张：飞到一半换掉它的进场方式，飞行会停住再跳到终点；它离开看板时才清
                if moving.isEmpty { return show(read, moved: moved.filter(read.holds)) }
                leaving = moving
                pending = read
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onChange(of: pending) {
                guard let pending, let board else { return }
                self.pending = nil
                show(pending, moved: pending.moved(from: board))
            }
            .onDayChange { day += 1 }
    }

    private func show(_ read: TaskBoard, moved: Set<String>) {
        withAnimation(Motion.spatial(Motion.move, reduceMotion: reduceMotion)) {
            self.moved = moved
            leaving = []
            board = read
        }
    }
}

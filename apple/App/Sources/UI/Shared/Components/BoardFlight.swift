import CueStore
import Synchronization
import SwiftUI

extension EnvironmentValues {
    /// 这一次读看板谁换了列（`observingBoard` 给）。
    @Entry var boardMoves: BoardMoves?
    /// 卡所在的那一列（行）的滚动区（`boardLane`）。
    @Entry var boardLane: TaskBoard.Column?
    /// 换列飞来的这张卡从哪一列来、落地没有（`BoardArrival`）：卡上叠着的原来那一列的纸色随着飞淡掉（`boardCard`）。
    @Entry var boardArrival: BoardArrival?
}

/// 飞来的卡起飞时是哪一列的纸；`landed` 从起飞的 false 变到 true 是在看板那一份的事务里，跟着它变的透明度随飞行插值。
struct BoardArrival: Equatable {
    let from: TaskBoard.Column
    let landed: Bool
}

/// 每次读看板谁换了列、各从哪一列来、原处在哪：换列的卡在原处撤掉、在新处飞来，都要在换上新看板的那一刻知道。
/// 撤掉的那张用的是它上一次排版时的样子（转场在它身上），那时还不知道看板要变，所以这一份不走环境的值，
/// 是读看板那一处在换上新看板之前写好（`read`）、两头在转场开始时来读的同一份（`BoardDepartures`）：新看板一步换上，不先排一次标出谁要走（多等一帧）。
/// 原处 = 卡在所在列（行）滚动区里的框（`frames`）+ 那个滚动区在看板坐标系里的框（`lanes`），都是排版、滚动后记下、不触发重绘。
/// 分两段记：卡直接记看板坐标系里的框的话，列里一让位每张卡每帧都要换算一遍跨过滚动区的坐标，大库里一次换列主线程多出近一半的指令。
/// 不用 `matchedGeometryEffect` 对两头：它取的是撤掉那张此刻的框，懒加载栈里撤掉的那张从第二帧起排在栈顶，飞的第一帧从列顶起跳。
@MainActor final class BoardMoves {
    /// 看板四列或四行的坐标系（`boardStage`）。
    static let space = "boardStage"

    nonisolated struct Departure: Sendable {
        let column: TaskBoard.Column
        let frame: CGRect
    }

    /// 这一次换了列、原处看得见的卡（原处没排出来的——懒加载还没建、滚出去了——不飞，在新处淡入）。
    let departures = BoardDepartures()
    /// 最近一次有卡换列时它们的身份：飞进去的那一列排在上面（`BoardColumn`），飞到一半又来一份没人换列的看板时不落到别的列下面。
    private var landing: Set<String> = []
    fileprivate var frames: [String: (lane: TaskBoard.Column, frame: CGRect)] = [:]
    fileprivate var lanes: [TaskBoard.Column: CGRect] = [:]

    fileprivate func read(_ moved: [String: TaskBoard.Column]) {
        departures.set(moved.reduce(into: [:]) { departures, move in
            guard let card = frames[move.key], let lane = lanes[card.lane] else { return }
            departures[move.key] = Departure(column: move.value, frame: card.frame.offsetBy(dx: lane.minX, dy: lane.minY))
        })
        if !moved.isEmpty { landing = Set(moved.keys) }
    }

    func lands(in flights: [String]) -> Bool { !landing.isEmpty && flights.contains(where: landing.contains) }
}

/// 这一次换了列的卡与原处（`BoardMoves.departures`）。iOS 上转场在渲染线程上求值，所以是加锁的一份，不是主线程上的状态。
nonisolated final class BoardDepartures: Sendable {
    private let state = Mutex<[String: BoardMoves.Departure]>([:])

    func callAsFunction(_ id: String) -> BoardMoves.Departure? { state.withLock { $0[id] } }

    fileprivate func set(_ departures: [String: BoardMoves.Departure]) { state.withLock { $0 = departures } }
}

extension View {
    /// 看板上一张卡的身份（`TaskBoard.Item.flight`、`Work.id`、`Held.id`：任务是 `task/…`，没绑任务的会话是 `session/…`，换列不换）。
    /// 卡换列是这一列删一张、那一列添一张，两张同一个身份，在同一个动画事务里（`observingBoard`）：
    /// - 旧的那张当场撤掉，新的那张在原处接上、平移到新处，只留一张在飞。它按这一列的终态排好，一路不重排、不缩放，只是渲染时的位移：
    ///   插值整个框的话每帧按插值的宽高重排一遍字，字逐帧挪动，主线程也跟不上；从旧的大小缩放过来的话，两列宽高比不同，字被横着拉宽；
    /// - 起飞时盖着原来那一列的纸色，随着飞淡掉（`BoardArrival`），纸色不在起飞那一下换；
    /// - 新来的（新建、取回归档、等你来了）在原处淡入，离开看板的（归档、删掉、等你答完）在原处淡出（`Motion.fade`），列里后面的卡挪上来补位。
    /// 不让旧的那张淡出、与新的交叉淡：懒加载栈里撤掉的那张从第二帧起排在栈顶，淡着的旧样子在列顶闪一下。
    /// 飞行要越过所在列、行的边，所以列与行的滚动区不裁内容（`scrollClipDisabled`；超出窗口的照样被窗口裁掉）。
    func boardFlight(_ id: String) -> some View { modifier(BoardFlight(id: id)) }

    /// 一列（行）卡的滚动区：卡飞的原处按它量（`BoardMoves`）。
    func boardLane(_ column: TaskBoard.Column) -> some View { modifier(BoardLaneFrame(column: column)) }
}

private struct BoardLaneFrame: ViewModifier {
    let column: TaskBoard.Column
    @Environment(\.boardMoves) private var moves

    func body(content: Content) -> some View {
        content
            .environment(\.boardLane, column)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardMoves.space)) } action: { moves?.lanes[column] = $0 }
    }
}

private struct BoardFlight: ViewModifier {
    let id: String
    @Environment(\.boardMoves) private var moves
    @Environment(\.boardLane) private var lane

    func body(content: Content) -> some View {
        if let moves, let lane {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { moves.frames[id] = (lane, $0) }
                .transition(.board(id, moves.departures))
        } else {
            content
        }
    }
}

extension Transition where Self == BoardPresence {
    /// 卡在看板上的进出（`boardFlight`）：三段合成，各走各的动画——飞（位移，照看板那一份的事务走）、淡（`Motion.fade`）、换列的旧那张当场撤（不动画）。
    /// 分段而不在一段里用 `animation(_:body:)` 给透明度单挂一条曲线：iOS 上转场在渲染线程上求值，那个闭包按主线程隔离，一调就崩。
    static func board(_ id: String, _ departures: BoardDepartures) -> some Transition {
        BoardPresence(id: id, departures: departures)
            .combined(with: BoardFade(id: id, departures: departures).animation(Motion.fade))
            .combined(with: BoardDrop(id: id, departures: departures).animation(nil))
    }
}

/// 换列飞来的那张从原处平移过来、起飞时盖着原来那一列的纸色（`BoardArrival`）。转场开始时才问这一次谁换了列（见 `BoardMoves`）。
/// 平移是渲染时插值的效果，起点与终点各算一次，途中每帧不重算卡的内容。撤掉的那张（`didDisappear`）什么都不加：
/// 给它换环境、挂效果，它所在的那一列会整列跳一下。
nonisolated struct BoardPresence: Transition {
    let id: String
    let departures: BoardDepartures

    func body(content: Content, phase: TransitionPhase) -> some View {
        let arrival = phase == .didDisappear ? nil : departures(id)
        content
            .environment(\.boardArrival, arrival.map { BoardArrival(from: $0.column, landed: phase.isIdentity) })
            .visualEffect { [start = phase == .willAppear ? arrival?.frame : nil] effect, proxy in
                let own = proxy.frame(in: .named(BoardMoves.space))
                let start = start ?? own
                return effect.offset(x: start.midX - own.midX, y: start.midY - own.midY)
            }
    }
}

/// 新来的在原处淡入、离开看板的在原处淡出；换列的两头不淡（飞来的那张一起飞就在，旧的那张由 `BoardDrop` 当场撤）。
nonisolated private struct BoardFade: Transition {
    let id: String
    let departures: BoardDepartures

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase.isIdentity || departures(id) != nil ? 1 : 0)
    }
}

/// 换列的旧那张当场撤掉、只留一张在飞。
nonisolated private struct BoardDrop: Transition {
    let id: String
    let departures: BoardDepartures

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase == .didDisappear && departures(id) != nil ? 0 : 1)
    }
}

extension View {
    /// 读看板（三端进展页同一处）：库变了重读；过了零点也重读一次——"今天做完"按读的那一刻分，库没变时日子换了也要换（同项目页）。
    /// 看板怎么动只在这里定：第一份是页面打开的样子、不动；之后每一份都在一个动画事务里换上（`Motion.travel`：换列是看板上最远的挪动，
    /// 列里让位跟着同一条走、与飞的那张同起同落；减弱动态效果时直接到终态，进出照样淡），各列各行不另挂动画。
    func observingBoard(into board: Binding<TaskBoard?>, store: CueStore, onError: @escaping (any Error) -> Void) -> some View {
        modifier(BoardReading(board: board, store: store, onError: onError))
    }
}

private struct BoardReading: ViewModifier {
    @Binding var board: TaskBoard?
    let store: CueStore
    let onError: (any Error) -> Void
    @State private var day = 0
    @State private var moves = BoardMoves()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.boardMoves, moves)
            .observing(store, id: day, into: Binding { board } set: { read in
                guard let board, let read else { return board = read }
                moves.read(read.moved(from: board))
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { self.board = read }
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onDayChange { day += 1 }
    }
}

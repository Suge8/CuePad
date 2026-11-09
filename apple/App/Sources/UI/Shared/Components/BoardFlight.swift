import CueStore
import Synchronization
import SwiftUI

extension EnvironmentValues {
    @Entry var boardMoves: BoardMoves?
    @Entry var boardLane: TaskBoard.Column?
}

/// 转场里写的环境键不带隔离（`BoardPresence`）。
nonisolated extension EnvironmentValues {
    @Entry var boardArrival: BoardArrival?
}

/// `landed` 从 false 变到 true 是在看板那一份的事务里，跟着它变的透明度随飞行插值。
nonisolated struct BoardArrival: Equatable {
    let from: TaskBoard.Column
    let landed: Bool
}

/// 撤掉的那张用的是它上一次排版时的样子（转场在它身上），那时还不知道看板要变，所以这一份不走环境的值，
/// 是读看板那一处在换上新看板之前写好（`read`）、两头在转场开始时来读的同一份（`BoardDepartures`）：新看板一步换上，不先排一次标出谁要走（多等一帧）。
/// 原处 = 卡在所在列（行）滚动区里的框（`frames`）+ 那个滚动区在看板坐标系里的框（`lanes`），都是排版、滚动后记下、不触发重绘。
/// 分两段记：卡直接记看板坐标系里的框的话，列里一让位每张卡每帧都要换算一遍跨过滚动区的坐标，大库里一次换列主线程多出近一半的指令。
/// 不用 `matchedGeometryEffect` 对两头：它取的是撤掉那张此刻的框，懒加载栈里撤掉的那张从第二帧起排在栈顶，飞的第一帧从列顶起跳。
@MainActor final class BoardMoves {
    nonisolated static let space = "boardStage"

    nonisolated struct Departure: Sendable {
        let column: TaskBoard.Column
        let frame: CGRect
        let at: ContinuousClock.Instant
    }

    /// 原处没排出来的（懒加载还没建、滚出去了）不飞，在新处淡入。
    let departures = BoardDepartures()
    /// 飞进去的那一列排在上面（`BoardColumn`），飞到一半又来一份没人换列的看板时不落到别的列下面。
    private var landing: Set<String> = []
    fileprivate var frames: [String: (lane: TaskBoard.Column, frame: CGRect)] = [:]
    fileprivate var lanes: [TaskBoard.Column: CGRect] = [:]

    /// `entered`（新来或离开看板的卡）这一趟不是飞，还没飞完的记录也撤掉，进出照常淡。
    fileprivate func read(_ moved: [String: TaskBoard.Column], entered: Set<String>) {
        let now = ContinuousClock.now
        departures.add(moved.reduce(into: [:]) { departures, move in
            guard let card = frames[move.key], let lane = lanes[card.lane] else { return }
            departures[move.key] = Departure(column: move.value, frame: card.frame.offsetBy(dx: lane.minX, dy: lane.minY), at: now)
        }, dropping: entered, at: now)
        if !moved.isEmpty { landing = Set(moved.keys) }
    }

    func lands(in flights: [String]) -> Bool { !landing.isEmpty && flights.contains(where: landing.contains) }
}

/// iOS 上转场在渲染线程上求值，所以是加锁的一份，不是主线程上的状态。
/// 一趟飞行要飞完才撤下（`Motion.Spring.travel` 收住的时长）：飞着时又来一份没人换列的看板，正在飞的那张、刚撤的那张再求值转场时照样认得出自己在飞；
/// 过了这么久就不算数；还没飞完就离开看板或又回来的，读看板那一处当场撤掉它的记录（`BoardMoves.read`），照常淡出淡入。
nonisolated final class BoardDepartures: Sendable {
    private let state = Mutex<[String: BoardMoves.Departure]>([:])
    private static let lasts = Duration.seconds(Motion.Spring.travel.settlingDuration)

    func callAsFunction(_ id: String) -> BoardMoves.Departure? {
        state.withLock { $0[id] }.flatMap { ContinuousClock.now - $0.at < Self.lasts ? $0 : nil }
    }

    fileprivate func add(_ departures: [String: BoardMoves.Departure], dropping gone: Set<String>, at now: ContinuousClock.Instant) {
        state.withLock { current in
            current = current.filter { now - $0.value.at < Self.lasts && !gone.contains($0.key) }.merging(departures) { _, new in new }
        }
    }
}

extension View {
    /// 卡换列是这一列删一张、那一列添一张，两张同一个身份（`TaskBoard.Item.flight`：任务是 `task/…`，没绑任务的会话是 `session/…`，换列不换），在同一个动画事务里（`observingBoard`）：旧的当场撤掉，新的在原处接上、平移到新处，只留一张在飞。
    /// 它按这一列的终态排好，一路不重排、不缩放，只是渲染时的位移：插值整个框的话每帧按插值的宽高重排一遍字，字逐帧挪动，主线程也跟不上；从旧的大小缩放过来的话，两列宽高比不同，字被横着拉宽。
    /// 不让旧的那张淡出、与新的交叉淡：懒加载栈里撤掉的那张从第二帧起排在栈顶，淡着的旧样子在列顶闪一下。
    /// 飞行要越过所在列、行的边，所以列与行的滚动区不裁内容（`scrollClipDisabled`；超出窗口的照样被窗口裁掉）。
    func boardFlight(_ id: String) -> some View { modifier(BoardFlight(id: id)) }

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
    /// 三段的 `body` 都写明 `nonisolated`：协议把它标成主线程，SwiftUI 在 iOS 上却由渲染线程求值（`com.apple.SwiftUI.AsyncRenderer`）。
    /// 只在类型上写 `nonisolated` 不够，`body` 照样从协议继承主线程隔离，里面的闭包都带主线程检查，渲染线程一调就崩；
    /// 写在 `body` 上，里面用到的类型、环境键、常量都得不带隔离，编译器替它把关。
    static func board(_ id: String, _ departures: BoardDepartures) -> some Transition {
        BoardPresence(id: id, departures: departures)
            .combined(with: BoardFade(id: id, departures: departures).animation(Motion.fade))
            .combined(with: BoardDrop(id: id, departures: departures).animation(nil))
    }
}

/// 平移是渲染时插值的效果，起点与终点各算一次，途中每帧不重算卡的内容。撤掉的那张（`didDisappear`）什么都不加：
/// 给它换环境、挂效果，它所在的那一列会整列跳一下。
nonisolated struct BoardPresence: Transition {
    let id: String
    let departures: BoardDepartures

    nonisolated func body(content: Content, phase: TransitionPhase) -> some View {
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

nonisolated private struct BoardFade: Transition {
    let id: String
    let departures: BoardDepartures

    nonisolated func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase.isIdentity || departures(id) != nil ? 1 : 0)
    }
}

nonisolated private struct BoardDrop: Transition {
    let id: String
    let departures: BoardDepartures

    nonisolated func body(content: Content, phase: TransitionPhase) -> some View {
        content.opacity(phase == .didDisappear && departures(id) != nil ? 0 : 1)
    }
}

extension View {
    /// 过了零点也重读一次："今天做完"按读的那一刻分，库没变时日子换了也要换。
    /// 看板怎么动只在这里定，各列各行不另挂动画：第一份是页面打开的样子、不动；之后每一份都在一个动画事务里换上（`Motion.travel`：换列是看板上最远的挪动，列里让位跟着同一条走、与飞的那张同起同落）。
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
                moves.read(read.moved(from: board), entered: read.entered(from: board))
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { self.board = read }
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onDayChange { day += 1 }
    }
}

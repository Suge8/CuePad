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
@MainActor @Observable final class BoardMoves {
    nonisolated static let space = "boardStage"

    nonisolated struct Departure: Sendable {
        let column: TaskBoard.Column
        let frame: CGRect
        let at: ContinuousClock.Instant
    }

    /// 原处没排出来的（懒加载还没建、滚出去了）不飞，在新处淡入。
    let departures = BoardDepartures()
    /// 飞进去的那一列排在上面（`BoardColumn`），飞到一半又来一份没人换列的看板时不落到别的列下面。
    @ObservationIgnored private var landing: Set<String> = []
    @ObservationIgnored var frames: [String: (lane: TaskBoard.Column, frame: CGRect)] = [:] { didSet { land() } }
    /// 此刻排出来的卡（值是那一份视图自己的记号）。懒加载撤掉的卡留着撤掉前的框：一下跳过几屏（拖滚动条）时那个框还在可视区里，
    /// 按住会拎起早已不在那儿的卡、排序会把它算进去，所以取框只认排出来的（`laid`）。
    @ObservationIgnored var shown: [String: UUID] = [:]
    /// 手机的行里各小列排在哪、从上到下是哪几张（`boardStack`）：行里卡的框由它算，不挂在卡上记。
    @ObservationIgnored var stacks: [UUID: Stack] = [:] { didSet { land() } }
    @ObservationIgnored var lanes: [TaskBoard.Column: CGRect] = [:]

    // 拖动（`BoardDrag.swift`）。几何不触发重绘；读得到的只有下面几样，手指每挪一下只写 `point`。
    /// 各列（行）连列头的框，看板坐标系；`origin` 是看板坐标系在窗口里的原点。
    @ObservationIgnored var areas: [TaskBoard.Column: CGRect] = [:]
    @ObservationIgnored var origin = CGPoint.zero
    @ObservationIgnored var reduceMotion = false
    /// 系统拖放放下的那一处（卡那么大的框）。
    @ObservationIgnored var hand: CGRect?
    /// 空位上一次挪开的时刻。
    @ObservationIgnored var shifted: ContinuousClock.Instant?
    @ObservationIgnored var aimed: (finger: CGPoint, board: TaskBoard, row: Bool)?
    /// 放下的卡要先答一句才办（`Workspace.asksAboutDrop`）：问着时它停在松手的地方，问完再等库（`pend`）。
    @ObservationIgnored var asking = false {
        didSet { if oldValue, !asking, held?.phase == .pending { pend() } }
    }
    /// 放下后等库的那一段（`pend`）。
    @ObservationIgnored var waiting: Task<Void, Never>?
    var held: Held?
    var float: Float?
    /// 浮着的那张的卡心。
    var point = CGPoint.zero
    var over: TaskBoard.Column?
    var slot: Int?
    var placed: Placed?
    var pull: Pull?

    /// 新来或离开看板的卡这一趟不是飞，还没飞完的记录也撤掉，进出照常淡。
    fileprivate func read(_ board: TaskBoard, from before: TaskBoard) {
        var moved = board.moved(from: before)
        let now = ContinuousClock.now
        // 放下后悬着的那张换了身份（`TaskBoard.renamed`）：手里这张跟着认新的，不然新的那张在原处露出来、手里这张还悬着；连列也换了的算换列
        var shed: (id: String, from: TaskBoard.Column, frame: CGRect)?
        if let held, held.phase == .pending, let new = board.renamed(held.id, from: before) {
            shed = frame(of: held.id).map { (held.id, new.from, $0) }
            self.held?.id = new.id
            if new.to != new.from { moved[new.id] = new.from }
        }
        if let hung = self.held, before.column(of: hung.id) != nil, board.column(of: hung.id) == nil { leave() }
        var from: [String: Departure] = moved.reduce(into: [:]) { departures, move in
            guard let frame = frame(of: move.key) else { return }
            departures[move.key] = Departure(column: move.value, frame: frame, at: now)
        }
        if let hand = takeoff(moved, lands: { board.column(of: $0) }), let column = moved[hand.id] { from[hand.id] = Departure(column: column, frame: hand.frame, at: now) }
        // 旧身份的那张当场藏掉（有飞行记录的撤掉时不淡，`BoardDrop`）：不然它在原处淡着露一下
        if let shed { from[shed.id] = Departure(column: shed.from, frame: shed.frame, at: now) }
        if board.todo.map(\.id) != before.todo.map(\.id) {
            // 放下的那一处库里排好了（或别处改了待办）：空位交还给库里的顺序
            if placed != nil { placed = nil }
            // 拖着时待办变了（同步插进来一张）：空位跟着它后面那张卡走，不留在原来的下标上——留着的话空位当场跳到别处，松手落的也是那一处
            if let slot, let id = held?.card.task, held?.phase == .dragging {
                let next = before.todo.indices.contains(slot) ? before.todo[slot].id : nil
                let wanted = next.flatMap { next in board.todo.firstIndex { $0.id == next } } ?? board.todo.count
                self.slot = board.slots(for: id).min { abs($0 - wanted) < abs($1 - wanted) }
            }
        }
        if aimed != nil { aimed?.board = board }
        departures.add(from, dropping: board.entered(from: before), at: now)
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
    @Environment(\.boardRow) private var row
    @State private var token = UUID()

    func body(content: Content) -> some View {
        if let moves, let lane {
            // 拖着的那张原处只留空位（`BoardDrag`）
            let held = moves.held.map { $0.id == id && $0.phase != .landing } ?? false
            content
                .opacity(held ? 0 : 1)
                .background { if held { BoardWell() } }
                // 手机的行里不在卡上记，由小列算（`boardStack`）
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { if !row { moves.frames[id] = (lane, $0) } }
                // 按记号认：卡换列时新的那份先出现、旧的那份后撤，旧的撤掉时不把新的也摘了
                .onAppear { if !row { moves.shown[id] = token } }
                .onDisappear { if moves.shown[id] == token { moves.shown[id] = nil } }
                .containerValue(\.boardFlight, id)
                .transition(.board(id, moves.departures))
        } else {
            content
        }
    }
}

extension ContainerValues {
    /// 手机的行按它认格里排的是哪张卡（`boardStack`）。
    @Entry var boardFlight: String?
}

extension BoardMoves {
    struct Stack {
        let lane: TaskBoard.Column
        var frame = CGRect.null
        /// 从上到下各格是哪张卡（飞行身份）；不是卡的格（"更早做完的"那一叠、空着的说明）为 nil。
        var ids: [String?] = []
        /// 一格的高，与格到格的间距。
        var height: CGFloat = 0
        var pitch: CGFloat = 0
    }
}

extension View {
    /// 手机的行里一小列（`BoardRowLane`）记它排在哪、里面是哪几张：行里各格一样高，卡的框按第几格算（`BoardMoves.laid`）。
    /// 不挂在卡上记：行把卡一格一格重新摆（`Group(subviews:)`），卡换小列时它身上那一份不报新位置（实测：卡的状态跟着卡走、位置却是另一格的），
    /// 留着的旧框正好盖在挪进它原处的那张卡上，按住那张拎起来的是它。也不挂在格上记：格上多套一层，卡换行时的飞行就丢了，旧的那张在原处露两帧（实测）。
    func boardStack(_ ids: [String?], in lane: TaskBoard.Column, height: CGFloat, pitch: CGFloat) -> some View {
        modifier(BoardStackSpot(ids: ids, lane: lane, height: height, pitch: pitch))
    }
}

private struct BoardStackSpot: ViewModifier {
    let ids: [String?]
    let lane: TaskBoard.Column
    let height: CGFloat
    let pitch: CGFloat
    @Environment(\.boardMoves) private var moves
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { moves?.stacks[token, default: BoardMoves.Stack(lane: lane)].frame = $0 }
            .onChange(of: [AnyHashable(ids), AnyHashable(height), AnyHashable(pitch)], initial: true) {
                var stack = moves?.stacks[token] ?? BoardMoves.Stack(lane: lane)
                (stack.ids, stack.height, stack.pitch) = (ids, height, pitch)
                moves?.stacks[token] = stack
            }
            .onDisappear { moves?.stacks[token] = nil }
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
                moves.read(read, from: board)
                withAnimation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion)) { self.board = read }
            }, onError: onError) { try TaskBoard.read(from: $0) }
            .onDayChange { day += 1 }
    }
}

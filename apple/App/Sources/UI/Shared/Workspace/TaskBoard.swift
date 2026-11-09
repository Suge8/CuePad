import CueStore
import Foundation

/// 列只是任务状态与等你的投影，不另存状态。
/// Cue 的提问不上看板：它只在 Cue 页的拍板卡上答，会话条与名牌的等你连它一起数、点了就去那里；列头只数列里的卡。
/// 每张卡写哪个会话的状态、点了进哪个会话只看 `Item.agent`（没绑任务的会话是 `Work.agent`）：与列在同一次读里取，
/// 卡在哪一列与卡上写的状态出自同一刻的库，不另读窗口里那一份交给的会话（`AgentLinks`）。顶层的口径同 `CueStore.taskCounts`。
nonisolated struct TaskBoard: Sendable, Equatable {
    enum Column: CaseIterable, Identifiable, Sendable {
        case todo, advancing, waiting, done

        var id: Self { self }

        /// 分列的唯一规则，看板（`read`）与任务气泡的列头都按它。
        static func of(_ task: Card, in tally: CueTally) -> Column {
            if tally.held.contains(task.id) { return .waiting }
            if tally.advancing.contains(where: { $0.task?.id == task.id }) { return .advancing }
            switch task.status {
            case .done: return .done
            case .inProgress: return .advancing
            default: return .todo
            }
        }

        var title: String {
            switch self {
            case .todo: String(localized: "待办")
            case .advancing: String(localized: "推进中")
            case .waiting: String(localized: "等你")
            case .done: String(localized: "已完成")
            }
        }
    }

    struct Item: Identifiable, Sendable, Equatable {
        var task: Card
        var project: Project?
        var steps: TaskProgress?
        var leaf: Card?
        /// 卡上的状态、线、"下一步"与点卡进哪个会话都只看它；没有会话为 nil，点卡打开任务。
        var agent: PiSessionListItem?
        var reaching = false
        var shot: CueShown?
        var id: UUID { task.id }
        /// 换列不换，与 `Work.id`、`Held.id` 同一种写法（`boardFlight`）。
        var flight: String { "task/\(id)" }
    }

    struct Work: Identifiable, Sendable, Equatable {
        var work: CueWork
        var item: Item?
        var loose: PiSessionListItem?
        var id: String { work.id }
        var agent: PiSessionListItem? { item?.agent ?? loose }

        var project: UUID {
            switch work {
            case .task(let board): board.task.projectID
            case .session(let session): TaskBoard.home(session)
            }
        }
    }

    static func home(_ session: PiSessionState) -> UUID { session.projectID ?? Project.defaultID }

    struct Held: Identifiable, Sendable, Equatable {
        /// 与推进中那张卡同一种身份，换列认得出是同一张；并行的几步同时等你时只有第一张是 `task/…`。
        var id: String
        var session: PiSessionState
        var item: Item?
        var deciding: Bool

        var title: String { item?.task.title(session: session.title) ?? session.title }
        var project: UUID { item?.task.projectID ?? TaskBoard.home(session) }
    }

    private(set) var todo: [Item]
    private(set) var advancing: [Work]
    /// 等你列的卡（`heldCards`），读的时候排好（不在主线程，页面重算不再排一遍）。
    private(set) var held: [Held]
    private(set) var done: [Item]
    private(set) var earlier: [Item]

    static let empty = TaskBoard(todo: [], advancing: [], held: [], done: [], earlier: [])

    private static func heldCards(
        _ tally: CueTally, from store: isolated CueStore, item: (Card) throws -> Item
    ) throws -> [Held] {
        let asking = tally.waiting.compactMap { wait in if case .session(let session, let task) = wait { (session, task) } else { nil } }
            .sorted { ($0.0.stateSince, $0.0.sessionID) < ($1.0.stateSince, $1.0.sessionID) }
        let waiting = asking.map { ($0.0, $0.1, true) } + tally.replies.map { ($0.session, $0.task, false) }
        var flown: Set<UUID> = []
        return try waiting.map { session, task, deciding in
            let item = try task.flatMap { try store.card($0) }.map(item)
            let id = item.flatMap { flown.insert($0.id).inserted ? $0.flight : nil } ?? "session/\(session.sessionID)"
            return Held(id: id, session: session, item: item, deciding: deciding)
        }
    }

    func moved(from before: TaskBoard) -> [String: Column] {
        let was = before.columns
        return columns.reduce(into: [:]) { moved, card in
            if let old = was[card.key], old != card.value { moved[card.key] = old }
        }
    }

    /// 比 `before` 多出来或少了的卡（新来、离开看板）：它们不是在飞的那张，进出照常淡（`boardFlight`）。
    func entered(from before: TaskBoard) -> Set<String> {
        Set(columns.keys).symmetricDifference(before.columns.keys)
    }

    private var columns: [String: Column] {
        Dictionary(Column.allCases.flatMap { column in flights(column).map { ($0, column) } }) { first, _ in first }
    }

    func flights(_ column: Column) -> [String] {
        switch column {
        case .todo: todo.map(\.flight)
        case .advancing: advancing.map(\.id)
        case .waiting: held.map(\.id)
        case .done: (done + earlier).map(\.flight)
        }
    }

    func count(_ column: Column) -> Int {
        switch column {
        case .todo: todo.count
        case .advancing: advancing.count
        case .waiting: held.count
        case .done: done.count
        }
    }

    func only(_ project: UUID?) -> TaskBoard {
        guard let project else { return self }
        let mine = { (item: Item) in item.task.projectID == project }
        var board = self
        board.todo = todo.filter(mine)
        board.advancing = advancing.filter { $0.project == project }
        board.held = held.filter { $0.project == project }
        board.done = done.filter(mine)
        board.earlier = earlier.filter(mine)
        return board
    }

    /// "全部"里相邻的卡可能是别的项目，拖动不悄悄换项目。位置没变、或它挂在已完成的上级下（显示在顶层、但不是顶层）时为 nil。
    func move(_ id: UUID, before target: UUID?) -> TaskMove? {
        guard let dragged = todo.first(where: { $0.id == id })?.task, dragged.parentID == nil, id != target else { return nil }
        func previous(in list: ArraySlice<Item>) -> UUID? {
            list.last { $0.task.projectID == dragged.projectID && $0.task.parentID == nil && $0.id != id }?.id
        }
        let rest = todo.filter { $0.id != id }
        let index = target.flatMap { target in rest.firstIndex { $0.id == target } } ?? rest.count
        let after = previous(in: rest[..<index])
        guard let current = todo.firstIndex(where: { $0.id == id }), after != previous(in: todo[..<current]) else { return nil }
        return TaskMove(slot: .top(project: dragged.projectID), after: after)
    }

    static func read(from store: isolated CueStore, now: Date = .now) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        let steps = try store.subtaskProgress()
        let open = TaskTree(try store.tasks(.inProgress, .todo).flatMap(\.tasks))
        let tally = try store.cueTally()
        let finished = try store.tasksDone().filter { Column.of($0, in: tally) == .done }
        let todo = open.roots.compactMap(open.task).filter { Column.of($0, in: tally) == .todo }
        let working = tally.advancing.compactMap { if case .task(let board) = $0 { board } else { nil } }
        let started = Set(working.map(\.id))
        let held = try tally.held.subtracting(started).compactMap { try store.card($0) }
        let others = try store.boardItems((todo + finished + held).filter { !started.contains($0.id) })
        let boards = Dictionary((working + others).map { ($0.id, $0) }) { first, _ in first }
        let loose = tally.advancing.compactMap { if case .session(let state) = $0 { state } else { nil } }
        let agents = try store.piSessions(sessionIDs: boards.values.compactMap(\.session?.sessionID) + loose.map(\.sessionID))
        func item(_ task: Card) throws -> Item {
            let progress = steps[task.id]
            let leaf = progress == nil ? task : task.status == .inProgress ? try store.workingLeaf(of: task.id) : nil
            let board = boards[task.id]
            return Item(
                task: task, project: projects[task.projectID], steps: progress, leaf: leaf, agent: board?.session.flatMap { agents[$0.sessionID] },
                reaching: board?.reaching ?? false)
        }
        // 置顶的不论哪天做完的都在已完成的最前（"全部归档"也留着它们），其余今天的在列里、更早的收在列末
        let pinned = finished.filter(\.isPinned), rest = finished.filter { !$0.isPinned }
        let today = Calendar.current.startOfDay(for: now)
        let split = rest.firstIndex { ($0.completedAt ?? .distantPast) < today } ?? rest.endIndex
        let results = try store.cueResultShots(of: finished)
        let previews = try store.previews(Set(results.values.joined().map(\.preview)))
        func finishedItem(_ task: Card) throws -> Item {
            var done = try item(task)
            done.shot = results[task.id]?.lazy.compactMap { shot in previews[shot.preview].map { CueShown(preview: $0, look: shot.look) } }.first
            return done
        }
        return TaskBoard(
            todo: try todo.map(item),
            advancing: try tally.advancing.map { work in
                switch work {
                case .task(let board): Work(work: work, item: try item(board.task))
                case .session(let state): Work(work: work, loose: agents[state.sessionID] ?? PiSessionListItem(state: state))
                }
            },
            held: try heldCards(tally, from: store, item: item),
            done: try (pinned + rest[..<split]).map(finishedItem),
            earlier: try rest[split...].map(finishedItem))
    }
}

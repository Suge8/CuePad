import CueStore
import Foundation

nonisolated struct TaskBoard: Sendable, Equatable {
    enum Column: CaseIterable, Identifiable, Sendable {
        case todo, advancing, waiting, done

        var id: Self { self }

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
            case .advancing: String(localized: "进行中")
            case .waiting: String(localized: "等你")
            case .done: String(localized: "已完成")
            }
        }
    }

    enum Flight: Hashable, Sendable {
        case task(UUID), session(String), well
    }

    struct Item: Identifiable, Sendable, Equatable {
        var task: Card
        var project: Project?
        var steps: TaskProgress?
        var leaf: Card?
        var agent: SessionListItem?
        var reaching = false
        var shot: CueShown?
        var id: UUID { task.id }
        var flight: Flight { .task(id) }
    }

    struct Work: Identifiable, Sendable, Equatable {
        var work: CueWork
        var item: Item?
        var loose: SessionListItem?
        var id: Flight {
            switch work {
            case .task(let board): .task(board.id)
            case .session(let session): .session(session.sessionID)
            }
        }
        var agent: SessionListItem? { item?.agent ?? loose }

        var project: UUID {
            switch work {
            case .task(let board): board.task.projectID
            case .session(let session): item?.task.projectID ?? TaskBoard.home(session)
            }
        }
    }

    static func home(_ session: SessionState) -> UUID { session.projectID ?? Project.defaultID }

    struct Held: Identifiable, Sendable, Equatable {
        var id: Flight
        var session: SessionState
        var item: Item?
        var deciding: Bool

        var title: String { item?.task.title(session: session.title) ?? session.title }
        var project: UUID { item?.task.projectID ?? TaskBoard.home(session) }
        var shown: SessionShown { SessionShown(status: deciding ? .asking : .awaitsReply) }
    }

    private(set) var todo: [Item]
    private(set) var advancing: [Work]
    private(set) var held: [Held]
    private(set) var done: [Item]
    private(set) var earlier: [Item]

    static let empty = TaskBoard(todo: [], advancing: [], held: [], done: [], earlier: [])

    private static func heldCards(
        _ tally: CueTally, from store: isolated CueStore, item: (Card) throws -> Item
    ) throws -> [Held] {
        let asking = tally.waiting.map { ($0.session, $0.task) }
            .sorted { ($0.0.stateSince, $0.0.sessionID) < ($1.0.stateSince, $1.0.sessionID) }
        let waiting = asking.map { ($0.0, $0.1, true) } + tally.replies.map { ($0.session, $0.task, false) }
        return try waiting.map { session, task, deciding in
            let item = try task.flatMap { try store.card($0) }.map(item)
            let id = item.flatMap { $0.agent?.state.sessionID == session.sessionID ? $0.flight : nil } ?? .session(session.sessionID)
            return Held(id: id, session: session, item: item, deciding: deciding)
        }
    }

    func moved(from before: TaskBoard) -> [Flight: Column] {
        let was = before.columns
        return columns.reduce(into: [:]) { moved, card in
            if let old = was[card.key], old != card.value { moved[card.key] = old }
        }
    }

    func renamed(_ id: Flight, from before: TaskBoard) -> (id: Flight, from: Column, to: Column)? {
        let now = columns, was = before.columns
        guard case .session(let session) = id, now[id] == nil, let old = was[id] else { return nil }
        let new = (todo + advancing.compactMap(\.item) + held.compactMap(\.item) + done + earlier).first {
            was[$0.flight] == nil && ($0.task.piSessionID == session || $0.task.formerSessionIDs.contains(session))
        }
        return new.flatMap { new in now[new.flight].map { (new.flight, old, $0) } }
    }

    func column(of flight: Flight) -> Column? { columns[flight] }

    func entered(from before: TaskBoard) -> Set<Flight> {
        Set(columns.keys).symmetricDifference(before.columns.keys)
    }

    private var columns: [Flight: Column] {
        Dictionary(Column.allCases.flatMap { column in flights(column).map { ($0, column) } }) { first, _ in first }
    }

    func flights(_ column: Column) -> [Flight] {
        switch column {
        case .todo: todo.map(\.flight)
        case .advancing: advancing.map(\.id)
        case .waiting: held.map(\.id)
        case .done: (done + earlier).map(\.flight)
        }
    }

    func draggables(_ column: Column) -> [(flight: Flight, card: DraggedCard)] {
        switch column {
        case .todo: todo.map { ($0.flight, .task($0.id)) }
        case .advancing: advancing.map { ($0.id, $0.item.map { .task($0.id) } ?? .session($0.loose?.state.sessionID ?? "")) }
        case .waiting: held.map { ($0.id, $0.item.map { .task($0.id) } ?? .session($0.session.sessionID)) }
        case .done: []
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

    private func placeable(_ id: UUID) -> Card? {
        let card = todo.first { $0.id == id }?.task ?? advancing.lazy.compactMap(\.item).first { $0.id == id }?.task
        return card?.parentID == nil ? card : nil
    }

    func slots(for id: UUID) -> [Int] {
        guard let project = placeable(id)?.projectID else { return [] }
        func own(_ index: Int) -> Bool { todo.indices.contains(index) && todo[index].task.projectID == project }
        return (0...todo.count).filter { own($0 - 1) || own($0) }
    }

    func move(_ id: UUID, before target: UUID?) -> TaskMove? {
        let current = todo.firstIndex { $0.id == id }
        guard let dragged = placeable(id), id != target else { return nil }
        func previous(in list: ArraySlice<Item>) -> UUID? {
            list.last { $0.task.projectID == dragged.projectID && $0.task.parentID == nil && $0.id != id }?.id
        }
        let rest = todo.filter { $0.id != id }
        let index = target.flatMap { target in rest.firstIndex { $0.id == target } } ?? rest.count
        let after = previous(in: rest[..<index])
        if let current, after == previous(in: todo[..<current]) { return nil }
        return TaskMove(slot: .top(project: dragged.projectID), after: after)
    }

    enum Drop {
        case place(UUID, TaskMove?)
        case backToTodo(UUID, TaskMove?)
        case start(Card)
        case finish(Item)
        case finishSession(SessionListItem)
        case endSession(SessionState)
    }

    func drop(_ card: DraggedCard, into column: Column, at slot: Int?) -> Drop? {
        switch (column, card) {
        case (.waiting, _), (_, .idea), (.advancing, .session): return nil
        case (.todo, .task(let id)):
            let move = slot.flatMap { move(id, before: todo.indices.contains($0) ? todo[$0].id : nil) }
            if advancing.contains(where: { $0.item?.id == id }) { return .backToTodo(id, move) }
            return slots(for: id).isEmpty ? nil : .place(id, move)
        case (.advancing, .task(let id)):
            return todo.first { $0.id == id }.map { .start($0.task) }
        case (.done, .task(let id)):
            return item(id).flatMap { $0.task.status == .done ? nil : .finish($0) }
        case (.todo, .session(let id)):
            return loose(id).flatMap { $0.state.canEnd ? .endSession($0.state) : nil }
        case (.done, .session(let id)):
            return loose(id).map(Drop.finishSession)
        }
    }

    func item(_ id: UUID) -> Item? {
        todo.first { $0.id == id } ?? advancing.lazy.compactMap(\.item).first { $0.id == id } ?? held.lazy.compactMap(\.item).first { $0.id == id }
            ?? done.first { $0.id == id } ?? earlier.first { $0.id == id }
    }

    private func loose(_ session: String) -> SessionListItem? {
        (advancing.compactMap(\.loose) + held.filter { $0.item == nil }.map { SessionListItem(state: $0.session) }).first { $0.state.sessionID == session }
    }

    static func read(from store: isolated CueStore, now: Date = .now) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        let steps = try store.subtaskProgress()
        let open = TaskTree(try store.tasks(.inProgress, .todo).flatMap(\.tasks))
        let tally = try store.cueTally()
        let finished = try store.tasksDone().filter { Column.of($0, in: tally) == .done }
        let todo = open.roots.compactMap(open.task).filter { Column.of($0, in: tally) == .todo }
        let working = tally.advancing.compactMap { if case .task(let board) = $0 { board } else { nil } }
        let held = try tally.held.compactMap { try store.card($0) }
        let others = try store.boardItems(todo + finished + held)
        let boards = Dictionary((working + others).map { ($0.id, $0) }) { first, _ in first }
        let loose = tally.advancing.compactMap { if case .session(let state) = $0 { state } else { nil } }
        let owners = Dictionary(tally.works.flatMap { work in work.task.map { task in work.sessions.map { ($0.sessionID, task) } } ?? [] }) { first, _ in first }
        let agents = try store.sessionItems(sessionIDs: boards.values.compactMap(\.session?.sessionID) + loose.map(\.sessionID))
        func item(_ task: Card) throws -> Item {
            let progress = steps[task.id]
            let leaf = progress == nil ? task : task.status == .inProgress ? try store.workingLeaf(of: task.id) : nil
            let board = boards[task.id]
            return Item(
                task: task, project: projects[task.projectID], steps: progress, leaf: leaf, agent: board?.session.flatMap { agents[$0.sessionID] },
                reaching: board?.reaching ?? false)
        }
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
                case .task(let board): return Work(work: work, item: try item(board.task))
                case .session(let state):
                    let agent = agents[state.sessionID] ?? SessionListItem(state: state)
                    guard let task = owners[state.sessionID] else { return Work(work: work, loose: agent) }
                    var running = try item(task)
                    running.agent = agent
                    return Work(work: work, item: running)
                }
            },
            held: try heldCards(tally, from: store, item: item),
            done: try (pinned + rest[..<split]).map(finishedItem),
            earlier: try rest[split...].map(finishedItem))
    }
}

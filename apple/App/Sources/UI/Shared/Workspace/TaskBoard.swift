import CueStore
import Foundation

/// 任务看板（进展页的看板一段）的四列，按流水排：待办 → 推进中 → 等你 → 已完成（今天）。列只是任务状态与等你的投影，不另存状态：
/// 一件任务只在一列：被会话等你占着的（`CueTally.held`）只在等你，Cue 在做的只在「推进中」，不论它的状态；其余按状态。
/// - 待办：没做完、Cue 也没在做的顶层任务（没开始的，和开始过而会话都结束了的），项目顺序、同级手动顺序（拖动排序只在同一项目的顶层里挪，`move`）。
/// - 推进中、等你：出自 `CueStore.cueTally`（Cue 那一行的同一份），"全部"下推进中的数与它相等；没绑没做完的任务的活会话在「推进中」里各一张。
///   推进中怎么排在画的时候定（置顶的在前，其余按要你管的先后，`Workspace.byAttention`）。
///   等你列只放在等你的会话，一个一张（`held`）、点了进那个会话：会话在问的在前，待回复的在后，各自等得最久的在上；没绑任务的会话也在。
///   Cue 的提问不上看板：它只在 Cue 页的拍板卡上答，底部那一排与侧栏的"等你 N"连它一起数、点了就去那里；列头只数列里的卡。
/// - 已完成：置顶的（不论哪天做完）在最前，接着今天做完的顶层任务（`CueStore.tasksDone`），最近的在前；更早做完的收在列末（`earlier`），没进归档，所以就地展开，不跳去归档页。
///   待办不另插队（本来就能拖着排），等你按等得多久排。
///   每件带上 Cue 做完时点名的第一张成果图（`CueStore.cueResultShots`，读的时候一次取齐，不逐行查库）。
/// 子任务不单列，卡片写进度。每张卡写哪个会话的状态、点了进哪个会话只看 `Item.agent`（没绑任务的会话是 `Work.agent`）：与列在同一次读里取，
/// 卡在哪一列与卡上写的状态出自同一刻的库，不另读窗口里那一份交给的会话（`AgentLinks`）。顶层的口径同 `CueStore.taskCounts`（`TaskTree` 的顶层）。
nonisolated struct TaskBoard: Sendable, Equatable {
    enum Column: CaseIterable, Identifiable, Sendable {
        case todo, advancing, waiting, done

        var id: Self { self }

        /// 一件顶层任务此刻在哪一列：分列的唯一规则，看板（`read`）与任务气泡的列头都按它。被等你占着的只在等你，Cue 在做的只在推进中，其余按状态。
        static func of(_ task: Card, in tally: CueTally) -> Column {
            if tally.held.contains(task.id) { return .waiting }
            if tally.advancing.contains(where: { $0.task?.id == task.id }) { return .advancing }
            return task.status == .done ? .done : .todo
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
        /// 此刻干活的叶子（`CueStore.workingLeaf`）：还没交给会话时"开始"开它。有子任务、不在进行中的为 nil（还没开始的由交给的规则定）。
        var leaf: Card?
        /// 卡上写的会话（`CueBoardItem.session`，此刻干活的那一步的，做完了的是最后做完那一步的）与发给它的最近一条话：
        /// 卡上的状态、线、"下一步"与点卡进哪个会话都只看它；没有会话为 nil，点卡打开任务。
        var agent: PiSessionListItem?
        /// 会话还在路上（正开会话、话正送进会话，`CueBoardItem.reaching`）：不再给"开始"。
        var reaching = false
        /// 已完成的：Cue 做完时点名的第一张成果图（还在的）；别的列为 nil。
        var shot: CueShown?
        var id: UUID { task.id }
        /// 卡在看板上的身份，换列不换：与推进中的 `Work.id`、等你的 `Held.id` 同一种写法（`boardFlight`）。
        var flight: String { "task/\(id)" }
    }

    /// 推进中的一件（`CueTally.advancing`）：在做的任务带那件任务，没绑没做完的任务的活会话没有。
    struct Work: Identifiable, Sendable, Equatable {
        var work: CueWork
        var item: Item?
        /// 没绑任务的会话自己（连同发给它的最近一条话）；任务的看 `item`。
        var loose: PiSessionListItem?
        var id: String { work.id }
        /// 这一件写的会话（`Item.agent` 或没绑任务的会话自己）。
        var agent: PiSessionListItem? { item?.agent ?? loose }

        /// 按项目筛时归哪个项目：任务的项目，会话的归处（`home`）。
        var project: UUID {
            switch work {
            case .task(let board): board.task.projectID
            case .session(let session): TaskBoard.home(session)
            }
        }
    }

    /// 一件等你：落在任务上的带那件任务。
    struct Wait: Identifiable, Sendable, Equatable {
        var wait: CueTally.Wait
        var item: Item?
        var id: String { wait.id }

        /// 这件事叫什么（拍板卡的眉题）：落在的任务名，没绑任务的会话名；不落在任务上的 Cue 提问没有这件事，为 nil。
        var title: String? {
            if let item { return item.task.title }
            if case .session(let session, _) = wait { return session.title }
            return nil
        }

        /// 等了多久从哪算：Cue 提问的时刻，会话进入等你的时刻。
        var since: Date {
            switch wait {
            case .message(let message, _): message.createdAt
            case .session(let session, _): session.stateSince
            }
        }

        /// 归哪个项目（眉题上写的是它）：落在的任务的项目，没落在任务上的会话看它的归处（`home`），
        /// Cue 的一般提问是它问时的范围（`CueMessage.asked`），没给范围的不属于哪个项目。
        var project: UUID? {
            if let item { return item.task.projectID }
            switch wait {
            case .session(let session, _): return TaskBoard.home(session)
            case .message(let message, _): return message.asked?.project
            }
        }
    }

    /// 没绑任务的会话归哪个项目：它的项目，没有项目的归默认项目（同 `PiSessionListItem.home`）。
    static func home(_ session: PiSessionState) -> UUID { session.projectID ?? Project.defaultID }

    /// 等你列的一张卡：一个在等你的会话，在问你（拍板，`asks` 是那一问）或待回复。写的名字同别的列：绑着的任务名，没绑任务的会话名。
    struct Held: Identifiable, Sendable, Equatable {
        /// 同推进中那张卡的身份（`Item.flight`、`CueWork.id`）：任务是 `task/…`（并行的几步同时等你时只有第一张是），其余是 `session/…`，换列认得出是同一张。
        var id: String
        var session: PiSessionState
        var item: Item?
        /// 会话在问你的那一问（与 Cue 页拍板卡同一份，`waits`）；待回复为 nil。
        var asks: Wait?

        var title: String { item?.task.title ?? session.title }
        /// 按项目筛时归哪个项目：绑着的任务的项目，否则会话的归处（`home`）。
        var project: UUID { item?.task.projectID ?? TaskBoard.home(session) }
    }

    private(set) var todo: [Item]
    private(set) var advancing: [Work]
    /// 等你列的卡（`heldCards`），读的时候排好（不在主线程，页面重算不再排一遍）。
    private(set) var held: [Held]
    private(set) var done: [Item]
    /// 更早做完的顶层任务，最近的在前。
    private(set) var earlier: [Item]

    static let empty = TaskBoard(todo: [], advancing: [], held: [], done: [], earlier: [])

    /// 等你列的卡：会话在问的在前、待回复的在后（`waits`、`CueTally.replies` 本来就各按等得最久的在前）；Cue 的提问不在内。
    private static func heldCards(_ waits: [Wait], _ replies: [(session: PiSessionState, item: Item?)]) -> [Held] {
        var flown: Set<UUID> = []
        func card(_ session: PiSessionState, _ item: Item?, asks: Wait?) -> Held {
            let id = item.flatMap { flown.insert($0.id).inserted ? $0.flight : nil } ?? "session/\(session.sessionID)"
            return Held(id: id, session: session, item: item, asks: asks)
        }
        let asking = waits.compactMap { wait in
            if case .session(let session, _) = wait.wait { card(session, wait.item, asks: wait) } else { nil }
        }
        return asking + replies.map { card($0.session, $0.item, asks: nil) }
    }

    /// 比 `before` 换了列的卡（`Item.flight`、`Work.id`、`Held.id`）与它原来在哪一列：看板据此让它从原处飞过去（`boardFlight`）。
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

    /// 每张卡在哪一列。
    private var columns: [String: Column] {
        Dictionary(Column.allCases.flatMap { column in flights(column).map { ($0, column) } }) { first, _ in first }
    }

    /// 一列里各张卡的身份（已完成连更早做完的）。
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

    /// 只看一个项目的（nil 是全部）。
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

    /// 在待办里把 `id` 拖到 `target` 前面（nil 是列末）：只在同一项目的顶层里挪，排在它前面最近的同项目任务之后——
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

    /// 等你那几件（Cue 页的拍板卡读同一份，`CueThread`）：最早的在前（等得最久的先答），落在任务上的带那件任务（`item` 按读的地方要的写）。
    static func waits(_ waiting: [CueTally.Wait], from store: isolated CueStore, item: (Card) throws -> Item) throws -> [Wait] {
        try waiting.map { wait in Wait(wait: wait, item: try wait.task.flatMap { try store.card($0) }.map(item)) }
            .enumerated().sorted { ($0.element.since, $0.offset) < ($1.element.since, $1.offset) }.map(\.element)
    }

    static func read(from store: isolated CueStore, now: Date = .now) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        let steps = try store.subtaskProgress()
        let open = TaskTree(try store.tasks(.inProgress, .todo).flatMap(\.tasks))
        let tally = try store.cueTally()
        let finished = try store.tasksDone().filter { Column.of($0, in: tally) == .done }
        let todo = open.roots.compactMap(open.task).filter { Column.of($0, in: tally) == .todo }
        // 每件事写哪个会话：推进中的 Cue 那份已经带着（`CueTally.advancing`），其余几列按同一条规则补上，会话连同发给它的话一次读齐
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
            held: heldCards(
                try waits(tally.waiting, from: store, item: item),
                try tally.replies.map { ($0.session, try $0.task.flatMap { try store.card($0) }.map(item)) }),
            done: try (pinned + rest[..<split]).map(finishedItem),
            earlier: try rest[split...].map(finishedItem))
    }
}

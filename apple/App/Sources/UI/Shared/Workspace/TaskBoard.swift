import CueStore
import Foundation

/// 任务看板（进展页的看板一段）的四列，按流水排：待办 → 推进中 → 等你 → 已完成（今天）。列只是任务状态与等你的投影，不另存状态：
/// 一件任务只在一列：被等你占着的（`CueTally.held`）只在等你，Cue 在做的只在「推进中」，不论它的状态；其余按状态。
/// - 待办：没做完、Cue 也没在做的顶层任务（没开始的，和开始过而会话都结束了的），项目顺序、同级手动顺序（拖动排序只在同一项目的顶层里挪，`move`）。
/// - 推进中、等你：就是 `CueStore.cueTally`（Cue 那一行的同一份），"全部"下列头的数与它相等；没绑没做完的任务的活会话在「推进中」里各一张。
///   推进中怎么排在画的时候定（置顶的在前，其余按要你管的先后，`Workspace.byAttention`）。
///   等你两种都放：拍板在前（与 Cue 页拍板卡同一份，`waits`），待回复在后（`replies`），各自等得最久的在上；没落在任务上的（Cue 的一般提问、没绑任务的会话）也在。
///   列里一件一张卡（`held`）：同一件任务上的几件等你收进一张，列头的数仍数条（"等你 N"，与各处相等）。
/// - 已完成：置顶的（不论哪天做完）在最前，接着今天做完的顶层任务（`CueStore.tasksDone`），最近的在前；更早做完的收在列末（`earlier`），没进归档，所以就地展开，不跳去归档页。
///   待办不另插队（本来就能拖着排），等你按等得多久排。
///   每件带上 Cue 做完时点名的第一张成果图（`CueStore.cueResultShots`，读的时候一次取齐，不逐行查库）。
/// 子任务不单列，卡片写进度；会话此刻在做什么看任务此刻干活的叶子（`Item.leaf`）。顶层的口径同 `CueStore.taskCounts`（`TaskTree` 的顶层）。
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
        /// 此刻干活的叶子（`CueStore.workingLeaf`）：会话状态与"开始"看它。有子任务、不在进行中的为 nil（还没开始的由交给的规则定）。
        var leaf: Card?
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
        var id: String { work.id }

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

        /// 这件事叫什么（拍板卡的眉题、看板的卡同一个）：落在的任务名，没绑任务的会话名；不落在任务上的 Cue 提问没有这件事，为 nil。
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

        /// 归哪个项目（按项目筛、卡与眉题上写的都是它）：落在的任务的项目，没落在任务上的会话看它的归处（`home`），
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

    /// 等你里待回复的一个会话（`CueTally.Reply`）：绑着任务的带那件任务。
    struct Reply: Identifiable, Sendable, Equatable {
        var reply: CueTally.Reply
        var item: Item?
        var id: String { reply.id }
        var session: PiSessionState { reply.session }

        /// 按项目筛时归哪个项目：绑着的任务的项目，否则会话的归处（`home`）。
        var project: UUID { item?.task.projectID ?? TaskBoard.home(reply.session) }
    }

    /// 看板上点了去哪（`Workspace.open(_:)`）：进会话，或去 Cue 页答拍板卡里的那一件（`Wait.id`）。
    enum Destination: Sendable, Equatable {
        case session(PiSessionState)
        case question(String)
    }

    /// 等你列的一张卡：一件任务一张，落在它上面的拍板与待回复都收在这里（换列不换名字）；没落在任务上的各一张。
    struct Held: Identifiable, Sendable, Equatable {
        var item: Item?
        /// 等得最久的在前。
        var waits: [Wait]
        var replies: [Reply]

        /// 同推进中那张卡的身份（`Item.flight`、`CueWork.id`）：任务是 `task/…`，没绑任务的会话是 `session/…`，换列认得出是同一张。
        var id: String { item?.flight ?? waits.first?.id ?? replies.first.map { "session/\($0.session.sessionID)" } ?? "" }
        /// 有一件拍板就是拍板（赭黄问号），只剩待回复是待回复（墨点）。
        var deciding: Bool { !waits.isEmpty }
        /// 收了几件（卡上大于 1 才写）。
        var count: Int { waits.count + replies.count }
        /// 卡上写的名字：这件事本身（`Wait.title`），不落在任务上的 Cue 提问写它要做的事（`CueAsking.action`）。
        var title: String {
            if let wait = waits.first { return wait.title ?? wait.message?.asking?.action ?? wait.message?.headline ?? "" }
            return item?.task.title ?? replies[0].session.title
        }
        var project: UUID? { item?.task.projectID ?? waits.first?.project ?? replies.first?.project }
        /// 点卡去最早的那件，拍板先于待回复：Cue 的提问去 Cue 页那一问，会话在问的与待回复进会话。
        var destination: Destination {
            if let wait = waits.first {
                switch wait.wait {
                case .message: return .question(wait.id)
                case .session(let session, _): return .session(session)
                }
            }
            return .session(replies[0].session)
        }
    }

    private(set) var todo: [Item]
    private(set) var advancing: [Work]
    /// 等你里的拍板。
    private(set) var waiting: [Wait]
    /// 等你里的待回复，排在拍板后面。
    private(set) var replies: [Reply]
    /// 等你列的卡（`group`），读的时候分好（不在主线程，页面重算不再分一遍）。
    private(set) var held: [Held]
    private(set) var done: [Item]
    /// 更早做完的顶层任务，最近的在前。
    private(set) var earlier: [Item]

    init(todo: [Item], advancing: [Work], waiting: [Wait], replies: [Reply], done: [Item], earlier: [Item]) {
        self.todo = todo
        self.advancing = advancing
        self.waiting = waiting
        self.replies = replies
        held = Self.group(waiting, replies)
        self.done = done
        self.earlier = earlier
    }

    static let empty = TaskBoard(todo: [], advancing: [], waiting: [], replies: [], done: [], earlier: [])

    /// 等你列的卡：拍板的卡在前、只剩待回复的在后，各按里面等得最久的那件排（`waiting`、`replies` 本来就是这个顺序）。
    private static func group(_ waiting: [Wait], _ replies: [Reply]) -> [Held] {
        var cards: [Held] = [], index: [UUID: Int] = [:]
        func add(_ item: Item?, _ fill: (inout Held) -> Void) {
            if let id = item?.id, let at = index[id] { return fill(&cards[at]) }
            var card = Held(item: item, waits: [], replies: [])
            fill(&card)
            if let id = item?.id { index[id] = cards.count }
            cards.append(card)
        }
        for wait in waiting { add(wait.item) { $0.waits.append(wait) } }
        for reply in replies { add(reply.item) { $0.replies.append(reply) } }
        return cards
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
        case .waiting: waiting.count + replies.count
        case .done: done.count
        }
    }

    /// 只看一个项目的（nil 是全部）：等你列的卡按卡的项目筛（一张卡里的几件同属一个项目），不重分。
    func only(_ project: UUID?) -> TaskBoard {
        guard let project else { return self }
        let mine = { (item: Item) in item.task.projectID == project }
        var board = self
        board.todo = todo.filter(mine)
        board.advancing = advancing.filter { $0.project == project }
        board.waiting = waiting.filter { $0.project == project }
        board.replies = replies.filter { $0.project == project }
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
        func item(_ task: Card) throws -> Item {
            let progress = steps[task.id]
            let leaf = progress == nil ? task : task.status == .inProgress ? try store.workingLeaf(of: task.id) : nil
            return Item(task: task, project: projects[task.projectID], steps: progress, leaf: leaf)
        }
        let open = TaskTree(try store.tasks(.inProgress, .todo).flatMap(\.tasks))
        let tally = try store.cueTally()
        let finished = try store.tasksDone().filter { Column.of($0, in: tally) == .done }
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
            todo: try open.roots.compactMap(open.task).filter { Column.of($0, in: tally) == .todo }.map(item),
            advancing: try tally.advancing.map { work in Work(work: work, item: try work.task.map(item)) },
            waiting: try waits(tally.waiting, from: store, item: item),
            replies: try tally.replies.map { Reply(reply: $0, item: try $0.task.flatMap { try store.card($0) }.map(item)) },
            done: try (pinned + rest[..<split]).map(finishedItem),
            earlier: try rest[split...].map(finishedItem))
    }
}

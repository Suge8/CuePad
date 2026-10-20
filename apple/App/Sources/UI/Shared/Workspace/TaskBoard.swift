import CueStore
import Foundation

/// 任务看板（Mac 任务页、手机任务页）的四列，按流水排：待办 → 在管 → 等你 → 做完（今天）。列只是任务状态与等你的投影，不另存状态：
/// - 待办：没开始的顶层任务，项目顺序、同级手动顺序（拖动排序只在同一项目的顶层里挪，`move`）。
/// - 在管、等你：就是 `CueStore.cueTally`（Cue 那一行的同一份），"全部"下列头的数与它相等；等你每件一张，没落在任务上的（Cue 的一般提问、没绑任务的会话）也在。
/// - 做完：今天做完的顶层任务，最近的在前；更早做完的收在列末（`earlier`），没进归档，所以就地展开，不跳去归档页。
/// 步骤不单列，卡片写进度；会话此刻在做什么看任务此刻干活的叶子（`Item.leaf`）。顶层的口径同 `CueStore.taskCounts`（`TaskTree` 的顶层）。
nonisolated struct TaskBoard: Sendable, Equatable {
    enum Column: CaseIterable, Identifiable, Sendable {
        case todo, managing, waiting, done

        var id: Self { self }

        var title: String {
            switch self {
            case .todo: "待办"
            case .managing: "在管"
            case .waiting: "等你"
            case .done: "做完"
            }
        }
    }

    struct Item: Identifiable, Sendable, Equatable {
        var task: Card
        var project: Project?
        var steps: TaskProgress?
        /// 此刻干活的叶子（`CueStore.workingLeaf`）：会话状态与"开始"看它。有步骤、还没开始的待办为 nil（开始时由交给的规则定）。
        var leaf: Card?
        var id: UUID { task.id }
    }

    /// 一件等你：落在任务上的带那件任务。
    struct Wait: Identifiable, Sendable, Equatable {
        var wait: CueTally.Wait
        var item: Item?
        var id: String { wait.id }

        /// 按项目筛时归哪个项目：落在的任务的项目，没落在任务上的会话看会话的项目；Cue 的一般提问不属于哪个项目。
        var project: UUID? {
            if let item { return item.task.projectID }
            if case .session(let session, _) = wait { return session.projectID }
            return nil
        }
    }

    var todo: [Item]
    var managing: [Item]
    var waiting: [Wait]
    var done: [Item]
    /// 更早做完的顶层任务，最近的在前。
    var earlier: [Item]

    static let empty = TaskBoard(todo: [], managing: [], waiting: [], done: [], earlier: [])

    /// 列头的数。
    func count(_ column: Column) -> Int {
        switch column {
        case .todo: todo.count
        case .managing: managing.count
        case .waiting: waiting.count
        case .done: done.count
        }
    }

    /// 只看一个项目的（nil 是全部）。
    func only(_ project: UUID?) -> TaskBoard {
        guard let project else { return self }
        let mine = { (item: Item) in item.task.projectID == project }
        return TaskBoard(
            todo: todo.filter(mine), managing: managing.filter(mine), waiting: waiting.filter { $0.project == project },
            done: done.filter(mine), earlier: earlier.filter(mine))
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

    static func read(from store: isolated CueStore, now: Date = .now) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        let steps = try store.subtaskProgress()
        func item(_ task: Card, started: Bool) throws -> Item {
            let progress = steps[task.id]
            let leaf = progress == nil ? task : started ? try store.workingLeaf(of: task.id) : nil
            return Item(task: task, project: task.projectID.flatMap { projects[$0] }, steps: progress, leaf: leaf)
        }
        let all = try store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let open = TaskTree(all.filter { $0.status != .done }, all: all)
        let finished = doneRoots(all)
        let today = Calendar.current.startOfDay(for: now)
        let tally = try store.cueTally()
        return TaskBoard(
            todo: try open.roots.compactMap(open.task).filter { $0.status == .todo }.map { try item($0, started: false) },
            managing: try tally.managing.map { try item($0, started: true) },
            waiting: try tally.waiting.map { wait in
                Wait(wait: wait, item: try wait.task.flatMap { try store.card($0) }.map { try item($0, started: true) })
            },
            done: try finished.prefix { ($0.completedAt ?? .distantPast) >= today }.map { try item($0, started: false) },
            earlier: try finished.drop { ($0.completedAt ?? .distantPast) >= today }.map { try item($0, started: false) })
    }

    /// 完成的顶层任务：`all`（同一范围里库中的全部任务）里完成了、上级不在其中的（与 `TaskCounts.done` 同一批），按完成时间从新到旧。
    private static func doneRoots(_ all: [Card]) -> [Card] {
        let listed = Set(all.map(\.id))
        return all.filter { $0.status == .done && !($0.parentID.map(listed.contains) ?? false) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// 项目页任务纸的"已完成"：最近完成的前 `doneLimit` 条，规则同看板的做完列。
    static func recentlyDone(_ all: [Card]) -> [Card] { Array(doneRoots(all).prefix(doneLimit)) }

    /// 项目页"已完成"列多少条。
    static let doneLimit = 30

    /// 各项目的进行中任务，最近开始的在前（项目的"此刻"一行，`ProjectNow`）：`started` 是 `CueStore.startedTasks()`，按项目归拢。
    static func leading(_ started: [Card]) -> [UUID: [ProjectNow.InProgress]] {
        var result: [UUID: [ProjectNow.InProgress]] = [:]
        for task in started {
            guard let project = task.projectID else { continue }
            result[project, default: []].append(ProjectNow.InProgress(id: task.id, title: task.title.textGlyphs))
        }
        return result
    }
}

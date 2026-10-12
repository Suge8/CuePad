import CoreGraphics
import CueStore
import Foundation

/// 一次结构上的移动：挂到哪、排在哪条同级之后（nil = 最前）。交给 `CueStore.moveTask`。
nonisolated struct TaskMove: Hashable, Sendable {
    var slot: CardSlot
    var after: UUID?
}

/// 拖动时的落点：要做的移动，以及界面上怎么标（悬停高亮的那一行，或两行之间的插入线与它的层级）。
nonisolated struct TaskDrop: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case onto(UUID)
        /// 插在 `after` 这一行（可见的行，nil = 最前）之下，层级 `depth`（0 起）。
        case gap(after: UUID?, depth: Int)
    }

    var move: TaskMove
    var mark: Mark
}

/// 一组任务的层级（手机任务页与项目页、Mac 任务面板与项目页共用）：按输入顺序（同级的手动顺序）建树，上级不在这组里的当顶层；
/// 排出可见的行，算缩进、反缩进与拖放落点各是哪一次移动。任务最多几级只在 `Card.maxTaskDepth`（提示词不在树里，不算一级）。
nonisolated struct TaskTree: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var task: Card
        /// 0 起。
        var depth: Int
        /// 这组里的直接子任务数。
        var childCount: Int
        var isExpanded: Bool
        var id: UUID { task.id }
    }

    private(set) var roots: [UUID] = []
    private var children: [UUID: [UUID]] = [:]
    private var parents: [UUID: UUID] = [:]
    private var tasks: [UUID: Card] = [:]
    private var order: [Card] = []
    /// 层级限制按库里的整棵树算（含已完成、不显示的子任务）：与 Store 写入时的校验同一口径。
    private var everything: [Card] = []
    private var structure = Structure([])

    /// 最深一级任务的缩进层数（0 起）。
    private static let deepest = Card.maxTaskDepth - 1

    /// `ordered` 是要显示的任务（同级手动顺序）；`all` 是同一范围里库中的全部任务（含已完成），省略时同 `ordered`。
    init(_ ordered: [Card], all: [Card]? = nil) {
        order = ordered
        everything = all ?? ordered
        structure = Structure(everything)
        tasks = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for task in ordered {
            if let parent = task.parentID, tasks[parent] != nil, parent != task.id {
                parents[task.id] = parent
                children[parent, default: []].append(task.id)
            } else {
                roots.append(task.id)
            }
        }
        // 环（远端并发、还没收敛）里的任务从顶层走不到：当顶层显示
        let reachable = Set(roots.flatMap { [$0] + descendants(of: $0) })
        for task in ordered where !reachable.contains(task.id) {
            parents[task.id] = nil
            roots.append(task.id)
        }
    }

    var isEmpty: Bool { tasks.isEmpty }
    /// 要显示的任务，按输入顺序。
    var ordered: [Card] { order }

    /// 只留这些顶层任务和它们的子树（看板的一组、项目页显示的前几条）：缩进、反缩进与拖放都只在里面算。
    func scoped(to roots: [UUID]) -> TaskTree {
        let kept = Set(roots.flatMap { [$0] + descendants(of: $0) })
        return TaskTree(order.filter { kept.contains($0.id) }, all: everything)
    }
    func task(_ id: UUID) -> Card? { tasks[id] }
    func children(of id: UUID) -> [UUID] { children[id] ?? [] }

    func depth(of id: UUID) -> Int {
        var depth = 0, cursor = parents[id]
        while let parent = cursor { depth += 1; cursor = parents[parent] }
        return depth
    }

    func descendants(of id: UUID) -> [UUID] { children(of: id).flatMap { [$0] + descendants(of: $0) } }

    /// 顶层默认展开、第二级默认折起（第三级藏在下面）；`toggled` 里的反过来。
    static func isExpanded(_ id: UUID, depth: Int, toggled: Set<UUID>) -> Bool { (depth == 0) != toggled.contains(id) }

    /// 可见的行：从 `roots`（默认全部顶层）往下，先序。
    func rows(of roots: [UUID]? = nil, toggled: Set<UUID>) -> [Row] {
        var rows: [Row] = []
        func visit(_ id: UUID, _ depth: Int) {
            guard let task = tasks[id] else { return }
            let expanded = Self.isExpanded(id, depth: depth, toggled: toggled)
            rows.append(Row(task: task, depth: depth, childCount: children(of: id).count, isExpanded: expanded))
            if expanded { for child in children(of: id) { visit(child, depth + 1) } }
        }
        for root in roots ?? self.roots { visit(root, 0) }
        return rows
    }

    // MARK: 缩进与反缩进

    /// 成为上一个同级的最后一个子任务；没有上一个同级、或整棵子树会超过最深一级时为 nil。
    func indent(_ id: UUID) -> TaskMove? {
        let siblings = parents[id].map(children(of:)) ?? roots
        guard let index = siblings.firstIndex(of: id), index > 0 else { return nil }
        let parent = siblings[index - 1]
        guard fits(id, under: parent) else { return nil }
        return TaskMove(slot: .under(parent), after: children(of: parent).last)
    }

    /// 成为原上级的下一个同级；顶层为 nil。
    func outdent(_ id: UUID) -> TaskMove? {
        guard let parent = parents[id] else { return nil }
        return TaskMove(slot: slot(under: parents[parent], project: tasks[parent]?.projectID), after: parent)
    }

    // MARK: 拖放

    /// 拖着 `dragged` 停在 `point`（与 `frames` 同一坐标系）时的落点。`rows` 是可见的行，`depthShift` 是手指横向挪了几级
    /// （右正左负）。停在一行中部是成为它的子任务（排在最后）；在两行之间时，层级取原层级加横移、夹在这个位置可取的范围内。
    /// 不能落进自己的子树；与原位置相同时为 nil。
    func drop(_ dragged: UUID, rows: [Row], frames: [UUID: CGRect], at point: CGPoint, depthShift: Int) -> TaskDrop? {
        let excluded = Set([dragged] + descendants(of: dragged))
        let candidates = rows.filter { !excluded.contains($0.id) && frames[$0.id] != nil }
        let height = structure.height(of: dragged)
        var gap: Int
        if let (index, fraction) = hit(point, in: candidates, frames: frames) {
            let row = candidates[index]
            if (0.25..<0.75).contains(fraction), fits(dragged, under: row.id) { return onto(row.id, dragged: dragged) }
            gap = fraction < 0.5 ? index : index + 1
        } else {
            gap = candidates.filter { frames[$0.id]!.midY < point.y }.count
        }
        let previous = gap > 0 ? candidates[gap - 1] : nil
        let next = gap < candidates.count ? candidates[gap] : nil
        // 落回原处（上下邻居与层级都没变）不动：顶层的上一行可能属于别的项目，按"落在它后面"算会悄悄换项目
        if let index = rows.firstIndex(where: { $0.id == dragged }) {
            let before = rows[..<index].last { !excluded.contains($0.id) }
            let after = rows[index...].first { !excluded.contains($0.id) }
            if before?.id == previous?.id, after?.id == next?.id, depthShift == 0 { return nil }
        }
        let lowest = next?.depth ?? 0
        let highest = min(previous.map { $0.depth + 1 } ?? 0, Self.deepest - height + 1)
        guard lowest <= highest else { return nil }
        // 想要的层级放不下（上级在库里比看上去深，或带着已完成的深层子任务）时往浅里退
        for depth in stride(from: min(max(depth(of: dragged) + depthShift, lowest), highest), through: lowest, by: -1) {
            let move = gapMove(dragged, depth: depth, previous: previous, next: next)
            if case .under(let parent) = move.slot, !fits(dragged, under: parent) { continue }
            guard move != current(dragged) else { return nil }
            return TaskDrop(move: move, mark: .gap(after: previous?.id, depth: depth))
        }
        return nil
    }

    /// 灵感拖到任务上成为提示词：落在哪一行就挂到它下面（整行都算，没有插入线——灵感不进任务的层级），排在它的下级之后；行外不接。
    /// 命中哪一行与任务拖放同一套（`hit`）。
    func drop(idea: UUID, rows: [Row], frames: [UUID: CGRect], at point: CGPoint) -> TaskDrop? {
        let candidates = rows.filter { frames[$0.id] != nil }
        return hit(point, in: candidates, frames: frames).map { onto(candidates[$0.index].id, dragged: idea) }
    }

    /// 点落在哪一行、在这一行的上下哪个位置（0 上沿，1 下沿）。
    private func hit(_ point: CGPoint, in rows: [Row], frames: [UUID: CGRect]) -> (index: Int, fraction: CGFloat)? {
        guard let index = rows.firstIndex(where: { frames[$0.id]!.minY <= point.y && point.y < frames[$0.id]!.maxY }) else { return nil }
        let frame = frames[rows[index].id]!
        return (index, (point.y - frame.minY) / frame.height)
    }

    private func onto(_ row: UUID, dragged: UUID) -> TaskDrop {
        TaskDrop(move: TaskMove(slot: .under(row), after: children(of: row).filter { $0 != dragged }.last), mark: .onto(row))
    }

    private func gapMove(_ dragged: UUID, depth: Int, previous: Row?, next: Row?) -> TaskMove {
        if let previous, depth == previous.depth + 1 { return TaskMove(slot: .under(previous.id), after: nil) }
        // 上一行在这一级（或更深处）的祖先就是新的上一个同级
        let sibling = previous.map { ancestor(of: $0.id, atDepth: depth) }
        let project = (sibling ?? next.map { ancestor(of: $0.id, atDepth: 0) }).flatMap { tasks[$0]?.projectID } ?? tasks[dragged]?.projectID
        return TaskMove(slot: slot(under: sibling.flatMap { parents[$0] }, project: project), after: sibling)
    }

    /// 挂到 `parent` 下整棵子树不超过最深一级（按库里的整棵树）。
    private func fits(_ id: UUID, under parent: UUID) -> Bool {
        structure.depth(of: parent) + structure.height(of: id) <= Self.deepest
    }

    private func ancestor(of id: UUID, atDepth target: Int) -> UUID {
        var cursor = id
        while depth(of: cursor) > target, let parent = parents[cursor] { cursor = parent }
        return cursor
    }

    private func slot(under parent: UUID?, project: UUID?) -> CardSlot {
        parent.map(CardSlot.under) ?? .top(project: project)
    }

    /// 原位置：同级（顶层按同一项目算，与 Store 的同级范围一致）里的上一条。
    private func current(_ id: UUID) -> TaskMove {
        let project = tasks[id]?.projectID
        let siblings = parents[id].map(children(of:)) ?? roots.filter { tasks[$0]?.projectID == project }
        let index = siblings.firstIndex(of: id) ?? 0
        return TaskMove(slot: slot(under: parents[id], project: project), after: index > 0 ? siblings[index - 1] : nil)
    }
}

/// 库里的层级（含不显示的任务）：只用来量深度与高度。
nonisolated private struct Structure: Equatable, Sendable {
    private var parents: [UUID: UUID] = [:]
    private var children: [UUID: [UUID]] = [:]

    init(_ tasks: [Card]) {
        let ids = Set(tasks.map(\.id))
        for task in tasks {
            guard let parent = task.parentID, ids.contains(parent), parent != task.id else { continue }
            parents[task.id] = parent
            children[parent, default: []].append(task.id)
        }
    }

    /// 0 起；远端并发留下的环走到重复处为止。
    func depth(of id: UUID) -> Int {
        var seen: Set<UUID> = [id], cursor = parents[id]
        while let parent = cursor, seen.insert(parent).inserted { cursor = parents[parent] }
        return seen.count - 1
    }

    /// 连自己在内往下有几级。
    func height(of id: UUID, seen: Set<UUID> = []) -> Int {
        guard !seen.contains(id) else { return 0 }
        return 1 + ((children[id] ?? []).map { height(of: $0, seen: seen.union([id])) }.max() ?? 0)
    }
}

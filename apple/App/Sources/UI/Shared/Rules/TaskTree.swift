import CoreGraphics
import CueStore
import Foundation

nonisolated struct TaskMove: Hashable, Sendable {
    var slot: CardSlot
    var after: UUID?
}

nonisolated struct TaskDrop: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        case onto(UUID)
        case gap(after: UUID?, depth: Int)
    }

    var move: TaskMove
    var mark: Mark
}

/// 任务最多几级只在 `Card.maxTaskDepth`。
nonisolated struct TaskTree: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        var task: Card
        var depth: Int
        var id: UUID { task.id }
    }

    private var links = Links([])
    private var tasks: [UUID: Card] = [:]
    private var order: [Card] = []
    /// 层级限制按库里的整棵树算（含已完成、不显示的子任务）：与 Store 写入时的校验同一口径。
    private var everything: [Card] = []
    private var structure = Links([])

    private static let deepest = Card.maxTaskDepth - 1

    /// `ordered` 是要显示的任务（同级手动顺序）；`all` 是同一范围里库中的全部任务（含已完成），省略时同 `ordered`。
    init(_ ordered: [Card], all: [Card]? = nil) {
        order = ordered
        everything = all ?? ordered
        structure = Links(everything)
        links = Links(ordered)
        tasks = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var roots: [UUID] { links.roots }
    private var parents: [UUID: UUID] { links.parents }

    var isEmpty: Bool { tasks.isEmpty }
    var ordered: [Card] { order }

    func scoped(to roots: [UUID]) -> TaskTree {
        TaskTree(roots.flatMap { [$0] + descendants(of: $0) }.compactMap { tasks[$0] }, all: everything)
    }
    func task(_ id: UUID) -> Card? { tasks[id] }
    func children(of id: UUID) -> [UUID] { links.children(of: id) }
    func depth(of id: UUID) -> Int { links.depth(of: id) }
    func descendants(of id: UUID) -> [UUID] { links.descendants(of: id) }

    func rows(of roots: [UUID]? = nil) -> [Row] {
        var rows: [Row] = []
        func visit(_ id: UUID, _ depth: Int) {
            guard let task = tasks[id] else { return }
            rows.append(Row(task: task, depth: depth))
            for child in children(of: id) { visit(child, depth + 1) }
        }
        for root in roots ?? self.roots { visit(root, 0) }
        return rows
    }

    /// 成为上一个同级的最后一个子任务；没有上一个同级、或整棵子树会超过最深一级时为 nil。
    func indent(_ id: UUID) -> TaskMove? {
        let siblings = parents[id].map(children(of:)) ?? roots
        guard let index = siblings.firstIndex(of: id), index > 0 else { return nil }
        let parent = siblings[index - 1]
        guard fits(id, under: parent) else { return nil }
        return TaskMove(slot: .under(parent), after: children(of: parent).last)
    }

    func outdent(_ id: UUID) -> TaskMove? {
        guard let parent = parents[id] else { return nil }
        return TaskMove(slot: slot(under: parents[parent], project: project(of: parent)), after: parent)
    }

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
        let project = project(of: sibling ?? next.map { ancestor(of: $0.id, atDepth: 0) } ?? dragged)
        return TaskMove(slot: slot(under: sibling.flatMap { parents[$0] }, project: project), after: sibling)
    }

    private func fits(_ id: UUID, under parent: UUID) -> Bool {
        structure.depth(of: parent) + structure.height(of: id) <= Self.deepest
    }

    private func ancestor(of id: UUID, atDepth target: Int) -> UUID {
        var cursor = id
        while depth(of: cursor) > target, let parent = parents[cursor] { cursor = parent }
        return cursor
    }

    private func slot(under parent: UUID?, project: UUID) -> CardSlot {
        parent.map(CardSlot.under) ?? .top(project: project)
    }

    private func project(of id: UUID) -> UUID { tasks[id]!.projectID }

    /// 原位置：同级（顶层按同一项目算，与 Store 的同级范围一致）里的上一条。
    private func current(_ id: UUID) -> TaskMove {
        let project = project(of: id)
        let siblings = parents[id].map(children(of:)) ?? roots.filter { tasks[$0]?.projectID == project }
        let index = siblings.firstIndex(of: id) ?? 0
        return TaskMove(slot: slot(under: parents[id], project: project), after: index > 0 ? siblings[index - 1] : nil)
    }
}

/// 库里没有环（本机写入校验、远端变更在同一事务里收敛，见 `CardLinks.repairs`），上级链与子树都走得到头。
nonisolated private struct Links: Equatable, Sendable {
    private(set) var roots: [UUID] = []
    private(set) var parents: [UUID: UUID] = [:]
    private var children: [UUID: [UUID]] = [:]

    init(_ tasks: [Card]) {
        let ids = Set(tasks.map(\.id))
        for task in tasks {
            if let parent = task.parentID, ids.contains(parent) {
                parents[task.id] = parent
                children[parent, default: []].append(task.id)
            } else {
                roots.append(task.id)
            }
        }
    }

    func children(of id: UUID) -> [UUID] { children[id] ?? [] }

    func descendants(of id: UUID) -> [UUID] { children(of: id).flatMap { [$0] + descendants(of: $0) } }

    func depth(of id: UUID) -> Int {
        var depth = 0, cursor = parents[id]
        while let parent = cursor { depth += 1; cursor = parents[parent] }
        return depth
    }

    func height(of id: UUID) -> Int { 1 + (children(of: id).map(height(of:)).max() ?? 0) }
}

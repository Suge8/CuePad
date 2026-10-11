import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务层级的界面规则（手机任务页与项目页、Mac 任务面板与项目页共用）：怎么排出可见的行、轻扫缩进与反缩进挪到哪、
/// 拖动时悬停在哪一行上成为它的子任务、落在两行之间按横向位置定层级。结果是交给 Store 的一次移动（`TaskMove`）。
@MainActor
struct TaskTreeRulesTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    /// a（a1（a1x）、a2）、b：按 Store 的顺序读出来建树。
    private func sample() async throws -> (tree: TaskTree, a: Card, a1: Card, a1x: Card, a2: Card, b: Card) {
        let a = try await store.createTask("a", in: nil)
        let b = try await store.createTask("b", in: nil)
        try await store.moveCard(a.id, to: .top(project: nil), after: nil)
        let a1 = try await store.createTask("a1", under: a.id)
        let a1x = try await store.createTask("a1x", under: a1.id)
        let a2 = try await store.createTask("a2", under: a.id)
        let tree = TaskTree(try await store.tasks(.todo).flatMap(\.tasks))
        return (tree, a, a1, a1x, a2, b)
    }

    @Test func 子任务跟在父任务下_第三级默认折起_展开后出现() async throws {
        let s = try await sample()

        let folded = s.tree.rows(toggled: [])
        #expect(folded.map(\.id) == [s.a.id, s.a1.id, s.a2.id, s.b.id])
        #expect(folded.map(\.depth) == [0, 1, 1, 0])
        #expect(folded[1].childCount == 1 && !folded[1].isExpanded)

        #expect(s.tree.rows(toggled: [s.a1.id]).map(\.id) == [s.a.id, s.a1.id, s.a1x.id, s.a2.id, s.b.id])
    }

    @Test func 父任务不在列表里的任务当顶层() async throws {
        let s = try await sample()
        let open = try await store.tasks(.todo).flatMap(\.tasks).filter { $0.id != s.a.id }
        #expect(TaskTree(open).rows(toggled: []).filter { $0.depth == 0 }.map(\.id) == [s.a1.id, s.a2.id, s.b.id])
    }

    @Test func 向右缩进成为上一个同级的最后一个子任务_没有上一个同级或会超过三级时不能缩进() async throws {
        let s = try await sample()
        #expect(s.tree.indent(s.b.id) == TaskMove(slot: .under(s.a.id), after: s.a2.id))
        #expect(s.tree.indent(s.a2.id) == TaskMove(slot: .under(s.a1.id), after: s.a1x.id))
        #expect(s.tree.indent(s.a.id) == nil)
        #expect(s.tree.indent(s.a1.id) == nil)
        // a2 有了子任务后，缩进会让它的子任务到第四级
        _ = try await store.createTask("a2x", under: s.a2.id)
        let deeper = TaskTree(try await store.tasks(.todo).flatMap(\.tasks))
        #expect(deeper.indent(s.a2.id) == nil)
    }

    @Test func 向左反缩进成为原父任务的下一个同级_顶层不能反缩进() async throws {
        let s = try await sample()
        #expect(s.tree.outdent(s.a1.id) == TaskMove(slot: .top(project: nil), after: s.a.id))
        #expect(s.tree.outdent(s.a1x.id) == TaskMove(slot: .under(s.a.id), after: s.a1.id))
        #expect(s.tree.outdent(s.b.id) == nil)
    }

    /// 每行高 44：a 0–44、a1 44–88、a2 88–132、b 132–176（a1x 折起）。
    private func frames(_ rows: [TaskTree.Row]) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
    }

    @Test func 拖到一行中部成为它的子任务_排在最后() async throws {
        let s = try await sample()
        let rows = s.tree.rows(toggled: [])
        let drop = s.tree.drop(s.b.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 66), depthShift: 0)
        #expect(drop?.move == TaskMove(slot: .under(s.a1.id), after: s.a1x.id))
        #expect(drop?.mark == .onto(s.a1.id))
    }

    @Test func 落在两行之间_横向位置定层级_夹在可选范围内() async throws {
        let s = try await sample()
        let rows = s.tree.rows(toggled: [])
        let gap = CGPoint(x: 100, y: 130)  // a2 下沿，b 之前；拖的是 b，所以这是末尾
        func move(_ shift: Int) -> TaskMove? { s.tree.drop(s.b.id, rows: rows, frames: frames(rows), at: gap, depthShift: shift)?.move }

        #expect(move(0) == nil)  // 原地不动
        #expect(move(1) == TaskMove(slot: .under(s.a.id), after: s.a2.id))
        #expect(move(2) == TaskMove(slot: .under(s.a2.id), after: nil))
        #expect(move(9) == TaskMove(slot: .under(s.a2.id), after: nil))
        // 在 a 与 a1 之间：下一行 a1 是第二级，所以只能是 a 的第一个子任务
        let top = s.tree.drop(s.b.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 42), depthShift: -3)
        #expect(top?.move == TaskMove(slot: .under(s.a.id), after: nil))
        #expect(top?.mark == .gap(after: s.a.id, depth: 1))
    }

    @Test func 不能拖进自己的子树() async throws {
        let s = try await sample()
        let rows = s.tree.rows(toggled: [])
        // a 的中部、a1 的中部都在 a 自己的子树里
        #expect(s.tree.drop(s.a.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 66), depthShift: 0) == nil)
        let afterB = s.tree.drop(s.a.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 174), depthShift: 0)
        #expect(afterB?.move == TaskMove(slot: .top(project: nil), after: s.b.id))
    }

    @Test func 灵感拖到任务行上_整行都算落在它上面_成为提示词排在最后_行外不接() async throws {
        let s = try await sample()
        let idea = try await store.createCard(in: nil, body: "日志")
        let rows = s.tree.rows(toggled: [])
        // a1 的上沿附近（任务拖到这里是插入线），灵感照样落在 a1 上
        let drop = s.tree.drop(idea: idea.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 46))
        #expect(drop == TaskDrop(move: TaskMove(slot: .under(s.a1.id), after: s.a1x.id), mark: .onto(s.a1.id)))
        #expect(s.tree.drop(idea: idea.id, rows: rows, frames: frames(rows), at: CGPoint(x: 100, y: 400)) == nil)
    }

    // MARK: 回归：层级限制与 Store 同一口径（已完成、不显示的子任务也算层级，界面给出的移动都应是 Store 接受的）；拖起来又放回原处什么都不改

    @Test func 带着已完成的第三级子任务的第二级任务_不能再缩进_也不能拖到别的第二级任务上() async throws {
        let top = try await store.createTask("上线", in: nil)
        let first = try await store.createTask("备份", under: top.id)
        let second = try await store.createTask("发布", under: top.id)
        let done = try await store.createTask("写说明", under: second.id)
        try await store.setStatus(done.id, .done)
        let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)

        #expect(tree.indent(second.id) == nil)

        let rows = tree.rows(toggled: [])
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let onto = tree.drop(second.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 66), depthShift: 0)
        #expect(onto?.mark != .onto(first.id))
        // 界面给出的移动，Store 都接受
        if let move = onto?.move { try await store.moveCard(second.id, to: move.slot, after: move.after) }
    }

    @Test func 拖起来放回原处不换项目_即使上一行属于别的项目() async throws {
        let site = try await store.createProject(name: "网站", color: "#000000")
        let loose = try await store.createTask("续费域名", in: nil)
        let other = try await store.createTask("换首图", in: site.id)
        let tree = TaskTree(try await store.tasks(.inProgress, .todo).flatMap(\.tasks))
        let rows = tree.rows(toggled: [])
        #expect(rows.map(\.id) == [other.id, loose.id])
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })

        #expect(tree.drop(loose.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 66), depthShift: 0) == nil)
    }
}

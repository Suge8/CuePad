import CueStore
import Foundation
import Testing
@testable import CuePad

/// 整理任务的层级：缩进、反缩进与拖放，界面给出的移动 Store 都接受；任务树怎么算从这些动作里走一遍，不单独测。
struct TaskOutlineTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    /// a（a1、a2）、b。界面给出的每一次移动，Store 都接受。
    @Test func 整理任务_缩进_反缩进_拖放_界面给出的移动Store都接受() async throws {
        let a = try await store.createTask("a")
        let b = try await store.createTask("b")
        try await store.moveCard(a.id, to: .top(project: Project.defaultID), after: nil)
        let a1 = try await store.createTask("a1", under: a.id)
        let a2 = try await store.createTask("a2", under: a.id)
        func tree() async throws -> TaskTree { TaskTree(try await store.tasks(.todo).flatMap(\.tasks)) }
        func apply(_ move: TaskMove?, _ id: UUID) async throws {
            let move = try #require(move)
            try await store.moveCard(id, to: move.slot, after: move.after)
        }

        let listed = try await tree().rows()
        #expect(listed.map(\.id) == [a.id, a1.id, a2.id, b.id] && listed.map(\.depth) == [0, 1, 1, 0])

        // 缩进成为上一个同级的最后一个子任务；没有上一个同级、或任务会超过两级时不能缩进
        #expect(try await tree().indent(a.id) == nil)
        #expect(try await tree().indent(a1.id) == nil)
        #expect(try await tree().indent(a2.id) == nil)
        try await apply(try await tree().indent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        // 反缩进成为原上级的下一个同级；顶层不能反缩进
        try await apply(try await tree().outdent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == nil)
        #expect(try await tree().outdent(b.id) == nil)

        // 拖到一行中部成为它的子任务；不能拖进自己的子树
        let rows = try await tree().rows()
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let middle = CGPoint(x: 100, y: 66)
        try await apply(try await tree().drop(b.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0)?.move, b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        #expect(try await tree().drop(a.id, rows: rows, frames: frames, at: middle, depthShift: 0) == nil)
    }

    /// 层级限制与 Store 同一口径：已完成、不显示的子任务也算层级；拖起来又放回原处什么都不改。
    /// 点掉已完成子任务的圆圈：不再算做完只有一种——它与已完成的上级清掉完成，开始过的回进行中、没开始过的回待办，在归档里的整件取回；
    /// 上级从子任务推出开始，子任务开始过它就跟着进行中。
    @Test func 点掉已完成子任务的圆圈_上级跟着不再算做完_整件取回归档() async throws {
        let task = try await store.createTask("发布")
        let step = try await store.createTask("跑检查", under: task.id)
        try await store.setStatus(step.id, .inProgress)
        let workspace = Workspace(services: rig.services)
        try await workspace.toggle(task.id)
        try await workspace.archive(task.id)
        #expect(try await store.card(step.id)?.status == .done)
        #expect(try await store.archived().count == 1)

        try await workspace.toggle(step.id)
        #expect(try await store.card(step.id)?.status == .inProgress)
        #expect(try await store.card(task.id)?.status == .inProgress)
        #expect(try await store.archived().isEmpty)
    }

    @Test func 带着已完成子任务的任务不能再缩进_拖起来放回原处不换项目() async throws {
        let second = try await store.createTask("发布")
        let first = try await store.createTask("备份")
        let done = try await store.createTask("写说明", under: second.id)
        try await store.setStatus(done.id, .done)
        let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        #expect(tree.indent(second.id) == nil)
        let rows = tree.rows()
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let onto = tree.drop(second.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0)
        #expect(onto?.mark != .onto(first.id))
        if let move = onto?.move { try await store.moveCard(second.id, to: move.slot, after: move.after) }

        let site = try await store.createProject(name: "网站", color: "#000000")
        let loose = try await store.createTask("续费域名")
        let other = try await store.createTask("换首图", in: site.id)
        let flat = TaskTree(try await store.tasks(.inProgress, .todo).flatMap(\.tasks).filter { [loose.id, other.id].contains($0.id) })
        let flatRows = flat.rows()
        let flatFrames = Dictionary(uniqueKeysWithValues: flatRows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let home = try #require(flatFrames[loose.id])
        #expect(flat.drop(loose.id, rows: flatRows, frames: flatFrames, at: CGPoint(x: 100, y: home.midY), depthShift: 0) == nil)
    }
}

import CueStore
import Foundation
import Testing
@testable import CuePad

struct TaskOutlineTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    /// 每行 44 高、从上往下排的行框（拖放的落点按它判）。
    private func rowFrames(of rows: [TaskTree.Row]) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
    }

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

        #expect(try await tree().indent(a.id) == nil)
        #expect(try await tree().indent(a1.id) == nil)
        #expect(try await tree().indent(a2.id) == nil)
        try await apply(try await tree().indent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        try await apply(try await tree().outdent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == nil)
        #expect(try await tree().outdent(b.id) == nil)

        let rows = try await tree().rows()
        let frames = rowFrames(of: rows)
        let middle = CGPoint(x: 100, y: 66)
        try await apply(try await tree().drop(b.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0)?.move, b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        #expect(try await tree().drop(a.id, rows: rows, frames: frames, at: middle, depthShift: 0) == nil)
    }

    @Test func 点掉已完成子任务的圆圈_上级跟着不再算做完_整件取回归档() async throws {
        let task = try await store.createTask("发布")
        let step = try await store.createTask("跑检查", under: task.id)
        try await store.setStatus(step.id, .inProgress)
        let workspace = Workspace(services: rig.services)
        try await workspace.complete(task.id)
        try await workspace.archive(task.id)
        #expect(try await store.card(step.id)?.status == .done)
        #expect(try await store.archived().count == 1)

        try await workspace.reopen(step.id)
        #expect(try await store.card(step.id)?.status == .inProgress)
        #expect(try await store.card(task.id)?.status == .inProgress)
        #expect(try await store.archived().isEmpty)
    }

    @Test func 带着已完成子任务的任务不能再缩进_拖起来放回原处不换项目() async throws {
        let second = try await store.createTask("发布")
        _ = try await store.createTask("备份")
        let done = try await store.createTask("写说明", under: second.id)
        try await store.setStatus(done.id, .done)
        let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        #expect(tree.indent(second.id) == nil)
        let rows = tree.rows()
        let frames = rowFrames(of: rows)
        #expect(tree.drop(second.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0) == nil)

        let site = try await store.createProject(name: "网站", color: "#000000")
        let loose = try await store.createTask("续费域名")
        let other = try await store.createTask("换首图", in: site.id)
        let flat = TaskTree(try await store.tasks(.inProgress, .todo).flatMap(\.tasks).filter { [loose.id, other.id].contains($0.id) })
        let flatRows = flat.rows()
        let flatFrames = rowFrames(of: flatRows)
        let home = try #require(flatFrames[loose.id])
        #expect(flat.drop(loose.id, rows: flatRows, frames: flatFrames, at: CGPoint(x: 100, y: home.midY), depthShift: 0) == nil)
    }
}

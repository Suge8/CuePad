import CueStore
import Foundation
import Testing
@testable import CuePad

/// 大纲落点的回归：层级限制在界面上与 Store 同一口径（已完成、不显示的子任务也算层级，界面给出的移动都应是 Store 接受的）；
/// 拖起来又放回原处什么都不改。
@MainActor
struct TaskTreeDropRegressionTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

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

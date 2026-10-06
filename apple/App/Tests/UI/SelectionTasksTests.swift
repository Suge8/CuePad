import CueStore
import Foundation
import Testing
@testable import CuePad

/// 编辑器里选中几行"转为任务"：每行一个任务，归当前项目，任务列表里与选中时的先后一致。
@MainActor
struct SelectionTasksTests {
    let rig = TestApp()

    @Test func 选中的每一行成为当前项目的一个任务_顺序与原文一致() async throws {
        let project = try await rig.services.store.createProject(name: "P", color: "#000000")
        let workspace = Workspace(services: rig.services)

        let count = try await workspace.addTasks(fromSelection: "- 写发布说明\n\n- 更新截图", in: project.id)

        #expect(count == 2)
        let tasks = try await rig.services.store.tasks(.todo).flatMap(\.tasks)
        #expect(tasks.map(\.content) == ["写发布说明", "更新截图"])
        #expect(tasks.allSatisfy { $0.projectID == project.id })
    }
}

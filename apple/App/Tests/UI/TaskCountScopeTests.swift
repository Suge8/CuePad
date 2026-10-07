#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目页标题"任务 n/m"、书架项目卡"N 项任务"都按顶层任务计，与看板分组同一个数；子任务进度只在上级那一行。
@MainActor
struct TaskCountScopeTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 项目页的完成数与书架项目卡的任务数都只算顶层任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let release = try await store.createTask("上线", in: project.id)
        let backup = try await store.createTask("备份", under: release.id)
        _ = try await store.createTask("发布", under: release.id)
        try await store.updateTask(backup.id) { $0.status = .done }
        let fix = try await store.createTask("修重连", in: project.id)
        try await store.updateTask(fix.id) { $0.status = .done }

        let page = try await ProjectPageData.read(project.id, from: store)
        let shelf = try await ShelfData.read(from: store)
        let board = try await TaskBoard.read(from: store)

        #expect(page.taskProgress == TaskProgress(done: 1, total: 2))
        #expect(shelf.entries.first { $0.project.id == project.id }?.openTasks == 1)
        #expect(board.counts.inProgress + board.counts.todo == 1)
    }
}
#endif

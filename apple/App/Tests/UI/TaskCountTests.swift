#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务计数的口径：书架的"任务"一行与任务页的分组标题是同一个数——顶层任务数，按顶层任务的状态分组（与看板一致）；
/// 子任务不另计，进度写在它的上级那一行里。
@MainActor
struct TaskCountTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 书架的任务一行与任务页分组同一个数_子任务不重复计() async throws {
        let release = try await store.createTask("上线")
        let backup = try await store.createTask("备份", under: release.id)
        _ = try await store.createTask("发布", under: release.id)
        try await store.updateTask(backup.id) { $0.status = .inProgress }
        let fix = try await store.createTask("修重连")
        try await store.updateTask(fix.id) { $0.status = .inProgress }
        _ = try await store.createTask("补用例", under: fix.id)

        let shelf = try await ShelfData.read(from: store)
        let board = try await TaskBoard.read(from: store)

        #expect(shelf.tasks?.inProgress == 1 && shelf.tasks?.todo == 1)
        #expect(shelf.tasks?.inProgress == board.inProgress.count && shelf.tasks?.todo == board.todo.count)
    }
}
#endif

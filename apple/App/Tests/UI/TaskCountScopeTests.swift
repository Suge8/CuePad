import CueStore
import Foundation
import Testing
@testable import CuePad

/// 同一个项目里，顶栏的"N 项任务"、任务纸里列出的行、任务页的分组与"最近完成"数的都是同一批顶层任务（`CueStore.taskCounts`）：
/// 子任务、归档与回收站里的不算，上级已完成而自己重新打开的子任务和上级被归档的子任务算顶层。
@MainActor
struct TaskCountScopeTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 各处写的任务数与列出的行是同一批顶层任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000").id
        let release = try await store.createTask("上线", in: project)
        let backup = try await store.createTask("备份", under: release.id)
        let publish = try await store.createTask("发布", under: release.id)
        try await store.setStatus(backup.id, .inProgress)
        try await store.setStatus(publish.id, .done)

        let fix = try await store.createTask("修重连", in: project)
        try await store.setStatus(fix.id, .done)

        let closed = try await store.createTask("收尾", in: project)
        let reopened = try await store.createTask("补文档", under: closed.id)
        try await store.setStatus(closed.id, .done)
        try await store.setStatus(reopened.id, .todo)

        let archived = try await store.createTask("旧的", in: project)
        _ = try await store.createTask("旧的子任务", under: archived.id)
        try await store.archive(archived.id)

        let stranded = try await store.createTask("上级归档了", in: project)
        let orphan = try await store.createTask("孤儿", under: stranded.id)
        try await store.archive(stranded.id)
        try await store.unarchive(orphan.id)

        let gone = try await store.createTask("删了的", in: project)
        try await store.trashCard(gone.id)

        let catalog = try await ProjectCatalog.read(from: store)
        let page = try await ProjectPageData.read(project, from: store)
        let board = try await TaskBoard.read(from: store)

        let open = [release.id, reopened.id, orphan.id]
        #expect(Set(page.tasks.roots) == Set(open))
        #expect(catalog.openTasks[project] == open.count)
        #expect(board.inProgress.count + board.todo.count == open.count)
        #expect(board.counts.open == open.count)

        let done = [fix.id, closed.id]
        #expect(Set(board.done.map(\.id)) == Set(done))
        #expect(board.counts.done == done.count)
        #expect(page.taskCounts == board.counts)
    }
}

import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务三态（手机任务页与项目页、Mac 任务面板共用的读法与操作）：待办 / 进行中 / 完成。
@MainActor
struct TaskBoardTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 任务页按进行中_待办_最近完成分组_跨项目_每条带所在项目() async throws {
        let site = try await store.createProject(name: "个人网站", color: "#000000")
        let table = try await store.createProject(name: "圆桌", color: "#000000")
        let draft = try await store.createTask("写首页文案", in: site.id)
        let tests = try await store.createTask("补 scheduler 测试", in: table.id)
        let domain = try await store.createTask("续费域名", in: nil)
        try await store.setStatus(tests.id, .inProgress)
        try await store.setStatus(domain.id, .done)

        let board = try await TaskBoard.read(from: store)

        #expect(board.inProgress.map(\.task.id) == [tests.id])
        #expect(board.inProgress.first?.project?.id == table.id)
        #expect(board.todo.map(\.task.id) == [draft.id])
        #expect(board.todo.first?.project?.id == site.id)
        #expect(board.done.map(\.task.id) == [domain.id])
        #expect(board.done.first?.project == nil)
    }

    @Test func 最近完成按完成时间统一排序_不按项目分组() async throws {
        // 按项目分组时未分类总排在最后；最新完成的放在未分类里，只有按完成时间统一排才会排第一
        let site = try await store.createProject(name: "个人网站", color: "#000000")
        let older = try await store.createTask("写首页文案", in: site.id)
        let newer = try await store.createTask("续费域名", in: nil)
        for task in [older, newer] {
            try await store.setStatus(task.id, .done)
            try await Task.sleep(for: .milliseconds(5))
        }

        let board = try await TaskBoard.read(from: store)

        #expect(board.done.map(\.task.id) == [newer.id, older.id])
    }

    @Test func 点圆圈_待办与进行中都变完成_完成的回到待办_开始把待办置为进行中() async throws {
        let workspace = Workspace(services: app.services)
        let todo = try await store.createTask("写首页文案", in: nil)
        let doing = try await store.createTask("补测试", in: nil)

        try await workspace.start(doing)
        #expect(try await store.card(doing.id)?.status == .inProgress)

        try await workspace.toggle(todo)
        try await workspace.toggle(doing)
        #expect(try await store.card(todo.id)?.status == .done)
        #expect(try await store.card(doing.id)?.status == .done)

        try await workspace.toggle(todo)
        #expect(try await store.card(todo.id)?.status == .todo)
    }

    @Test func 项目页写本项目任务完成数与总数_按手动顺序列出本项目没完成的() async throws {
        let site = try await store.createProject(name: "个人网站", color: "#000000")
        let a = try await store.createTask("写首页文案", in: site.id)
        let b = try await store.createTask("换首图", in: site.id)
        let c = try await store.createTask("上线", in: site.id)
        _ = try await store.createTask("别的项目的", in: nil)
        try await store.setStatus(a.id, .done)
        try await store.setStatus(b.id, .inProgress)

        let page = try await ProjectPageData.read(site.id, from: store)

        #expect(page.taskProgress == TaskProgress(done: 1, total: 3))
        // 新任务在最前；进行中不再提前（手动排过的顺序不被状态打乱）
        #expect(page.tasks.rows(toggled: []).map(\.id) == [c.id, b.id])
    }

    @Test func 交给Pi的任务自动进行中_任务行带着那个会话的实时状态() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        try await recorder.update(sessionID: "s1", state: .tool, detail: "bash · pnpm test", title: "atlas")
        let task = try await store.createTask("补 scheduler 测试", in: nil)

        try await store.recordSend(task.body, to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: task.id)

        let board = try await TaskBoard.read(from: store)
        #expect(board.inProgress.map(\.task.id) == [task.id])
        #expect(board.inProgress.first?.session?.sessionID == "s1")
        #expect(board.inProgress.first?.session?.state == .known(.tool))
    }

    @Test func 列表第三行_Pi在想还没有动作时写正在处理的提问() {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = PiSessionState(
            id: UUID(), sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(.thinking), detail: nil, folder: nil,
            lastPrompt: "找原因", lastReply: "找到原因了。", question: nil, notify: nil, stateSince: now, busySince: nil, createdAt: now,
            modifiedAt: now, pendingPrompt: "把断言也改了\n顺便跑一遍")
        #expect(PiProgress.line(of: session) == "正在处理：把断言也改了")
    }
}

#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 跨项目任务不占标签：书架上一行入口（有任务时才有），点进去是任务页；记下任务后的提示、项目页的"还有 N 条"也去那里。
@MainActor
struct TaskEntryTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 书架的任务入口_写进行中与待办数_没有任务时没有() async throws {
        #expect(try await ShelfData.read(from: store).tasks == nil)
        let started = try await store.createTask("补 scheduler 测试")
        _ = try await store.createTask("续费域名")
        let finished = try await store.createTask("写首页文案")
        try await store.updateTask(started.id) { $0.status = .inProgress }
        try await store.updateTask(finished.id) { $0.status = .done }

        let tasks = try #require(try await ShelfData.read(from: store).tasks)

        #expect(tasks.inProgress == 1)
        #expect(tasks.todo == 1)
    }

    @Test(arguments: [Navigation.Layout.tabs, .split])
    func 去任务页_iPhone在项目标签里推入_iPad选中侧栏(layout: Navigation.Layout) {
        let navigation = Navigation()
        navigation.layout = layout
        navigation.tab = .agent
        navigation.projectsPath = [.today]

        navigation.showTasks()

        switch layout {
        case .tabs:
            #expect(navigation.tab == .projects)
            #expect(navigation.projectsPath == [.tasks])
        case .split:
            #expect(navigation.splitRoot == .tasks)
            #expect(navigation.splitPath.isEmpty)
        }
    }
}
#endif

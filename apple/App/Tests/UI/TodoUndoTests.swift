import CueStore
import Foundation
import Testing
@testable import CuePad

/// "要做"开关（轻扫、菜单、任务浮窗共用 `Workspace.setTodo`）：灵感变任务后提示里能撤销，撤销后回到原来那条灵感。
@MainActor
struct TodoUndoTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 灵感设为任务_提示可撤销_撤销后回到灵感() async throws {
        let idea = try await store.createCard(in: nil, body: "给 scheduler 补重连测试")
        let workspace = Workspace(services: rig.services)

        try await workspace.setTodo(idea.id, true)
        #expect(workspace.notice?.text == "已设为任务")
        #expect(try await store.card(idea.id)?.isTask == true)

        let undo = try #require(workspace.notice?.action)
        try await undo.run()
        #expect(try await store.card(idea.id)?.isTask == false)
        #expect(try await store.cards(in: nil).map(\.id) == [idea.id])
    }
}

import CueStore
import Foundation
import Testing
@testable import CuePad

/// 行的轻扫露出哪些动作（`CardMenu.swipes`，系统列表与自绘的大纲、卡片共用）：排在前面的是最外侧那颗、一滑到底执行的那个；
/// 做不了的动作不出现。删除走 `Workspace.trash`，提示里可撤销。
@MainActor
struct SwipeActionsTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 任务_右滑缩进_左滑删除与反缩进_做不了的不出现() async throws {
        let parent = try await store.createTask("上线", in: nil)
        let child = try await store.createTask("写 changelog", under: parent.id)
        let task = try #require(try await store.card(child.id))

        #expect(CardMenu.swipes(for: task, indent: true, outdent: true) == .init(leading: [.indent], trailing: [.trash, .outdent]))
        #expect(CardMenu.swipes(for: parent, indent: false, outdent: false) == .init(leading: [], trailing: [.trash]))
    }

    @Test func 灵感_右滑挂到任务_左滑删除与设为任务() async throws {
        let idea = try await store.createCard(in: nil, body: "给 scheduler 补重连测试")
        #expect(CardMenu.swipes(for: idea, indent: false, outdent: false) == .init(leading: [.attachToTask], trailing: [.trash, .makeTask]))
    }

    @Test func 删除进回收站_提示可撤销_撤销后回来() async throws {
        let idea = try await store.createCard(in: nil, body: "续费域名")
        let workspace = Workspace(services: rig.services)

        try await workspace.trash(idea.id)
        #expect(workspace.notice?.text == "已删除")
        #expect(try await store.trashedCards().map(\.id) == [idea.id])

        try await #require(workspace.notice?.action).run()
        #expect(try await store.trashedCards().isEmpty)
        #expect(try await store.cards(in: nil).map(\.id) == [idea.id])
    }
}

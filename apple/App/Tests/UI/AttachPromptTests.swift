import CueStore
import Foundation
import Testing
@testable import CuePad

/// 把灵感挂到任务下，它就成了任务的一条提示词：从灵感里挑或拖到任务行上，排在已有下级之后，不改变"灵感 / 任务"。
@MainActor
struct AttachPromptTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 挑一条灵感_成为任务的提示词_排在最后() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let sub = try await store.createTask("复现", under: task.id)
        let idea = try await store.createCard(in: project.id, body: "日志在 logs/0918.txt")
        let workspace = Workspace(services: rig.services)

        try await workspace.attach(idea.id, to: task.id)

        #expect(try await store.children(of: task.id).map(\.id) == [sub.id, idea.id])
        #expect(try await store.card(idea.id)?.isTask == false)
        #expect(try await store.cards(in: project.id).isEmpty)
    }

    @Test func 拖上去成为提示词_提示可撤销_撤销后回到原来的位置() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let first = try await store.createCard(in: project.id, body: "后记")
        let idea = try await store.createCard(in: project.id, body: "日志")  // 新建的在最前：idea、first
        let workspace = Workspace(services: rig.services)
        let before = try await store.cards(in: project.id).map(\.id)

        try await workspace.attach(idea.id, TaskMove(slot: .under(task.id), after: nil))
        #expect(try await store.children(of: task.id).map(\.id) == [idea.id])
        #expect(workspace.notice?.text == "已成为任务的提示词")

        try await #require(workspace.notice?.action).run()
        #expect(try await store.children(of: task.id).isEmpty)
        #expect(try await store.cards(in: project.id).map(\.id) == before)
        #expect(before.contains(first.id))
    }
}

import CueStore
import Foundation
import Testing
@testable import CuePad

/// 把灵感挂到任务下，它就成了任务的一条提示词：从灵感里挑或拖到任务行上，排在已有下级之后，不改变"灵感 / 任务"。
@MainActor
struct AttachPromptTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 挂到新建的任务_任务建在灵感所在的项目_灵感成为它的提示词() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let idea = try await store.createCard(in: project.id, body: "日志在 logs/0918.txt")
        let workspace = Workspace(services: rig.services)

        try await workspace.attachToNewTask(idea.id, title: "修乱序")

        let task = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.title == "修乱序" })
        #expect(task.projectID == project.id)
        #expect(try await store.children(of: task.id).map(\.id) == [idea.id])
        #expect(workspace.notice?.text == "已成为任务的提示词")
    }

    @Test func 挂到任务的候选_本项目的任务在前_其余按项目顺序分组_做完的不列() async throws {
        let a = try await store.createProject(name: "A", color: "#000000")
        let b = try await store.createProject(name: "B", color: "#000000")
        let inA = try await store.createTask("A 的任务", in: a.id)
        let inB = try await store.createTask("B 的任务", in: b.id)
        let done = try await store.createTask("做完了", in: b.id)
        try await store.setStatus(done.id, .done)
        let loose = try await store.createTask("没项目的", in: nil)
        let idea = try await store.createCard(in: b.id, body: "想法")

        let groups = try await AttachTargets.read(for: idea, from: store)

        #expect(groups.map(\.projectID) == [b.id] + (try await store.projects().map(\.id).filter { $0 != b.id }) + [nil])
        #expect(groups.flatMap(\.tasks).map(\.id).sorted() == [inA.id, inB.id, loose.id].sorted())
    }

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

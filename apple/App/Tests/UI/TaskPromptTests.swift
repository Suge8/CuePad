import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务就是给 Agent 的话：长按菜单最多四项加删除（共用一处定义），低频的在浮窗与纸页的"⋯"里；
/// 任务行看得出话写没写、交没交出去，任务浮窗读得到每一次发出去的原文。
@MainActor
struct TaskPromptTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 长按菜单_灵感是交给Agent设为任务移到项目归档_删除单独在最后() async throws {
        let idea = try await store.createCard(in: nil, body: "想法")
        #expect(CardMenu.sections(for: idea) == [[.handToAgent, .makeTask, .move, .archive], [.trash]])
    }

    @Test func 长按菜单_任务是交给Agent完成或重新打开归档_删除单独在最后() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(CardMenu.sections(for: task) == [[.handToAgent, .complete, .archive], [.trash]])

        try await store.setStatus(task.id, .done)
        let done = try #require(try await store.card(task.id))
        #expect(CardMenu.sections(for: done) == [[.handToAgent, .reopen, .archive], [.trash]])
    }

    @Test func 更多菜单_低频操作在浮窗与纸页的更多里() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let sub = try await store.createTask("复现", under: task.id)
        #expect(CardMenu.more(for: task) == [[.move, .sends, .copy], [.makeIdea, .archive], [.trash]])
        // 子任务跟着上级走，不单独换项目
        #expect(CardMenu.more(for: sub) == [[.sends, .copy], [.makeIdea, .archive], [.trash]])

        let idea = try await store.createCard(in: nil, body: "想法")
        #expect(CardMenu.more(for: idea) == [[.makeTask, .resource, .move, .copy], [.archive], [.trash]])
        try await store.updateCard(idea.id) { $0.isPinned = true }
        #expect(CardMenu.more(for: try #require(try await store.card(idea.id)))[0] == [.makeTask, .unresource, .move, .copy])
    }

    @Test func 完成任务后提示里给归档_点了就归档() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let workspace = Workspace(services: rig.services)

        try await workspace.toggle(task)
        #expect(workspace.notice?.text == "已完成")
        let action = try #require(workspace.notice?.action)
        #expect(action.title == "归档")

        try await action.run()
        #expect(try await store.card(task.id)?.archivedAt != nil)
    }

    @Test func 任务行的提示_只有标题是没写_写了要求是已写_交给过Agent是已交出() async throws {
        let bare = try await store.createTask("修乱序", in: nil)
        let written = try await store.createTask("修乱序\n\n跑 scheduler 测试，先别改代码", in: nil)
        #expect(PromptMark(bare) == .none)
        #expect(PromptMark(written) == .written)

        try await store.recordSend(written.body, to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: written.id)
        #expect(PromptMark(try #require(try await store.card(written.id))) == .handedOff)
    }

    @Test func 任务浮窗读到这条任务每次发出的原文_最近的在前() async throws {
        let task = try await store.createTask("修乱序\n\n第一版", in: nil)
        let other = try await store.createTask("别的", in: nil)
        try await store.recordSend("第一版", to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: task.id)
        try await store.recordSend("别的", to: SendTarget(kind: .clipboard, name: "剪贴板"), card: other.id)
        try await store.recordSend("第二版", to: SendTarget(kind: .clipboard, name: "剪贴板"), card: task.id)

        let detail = try await TaskDetail.read(task.id, from: store)
        #expect(detail.sends.map(\.content) == ["第二版", "第一版"])
    }
}

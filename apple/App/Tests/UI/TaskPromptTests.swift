import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务就是给 Agent 的话：长按菜单只留没有手势的几项（共用一处定义），任务行看得出话写没写、交没交出去，
/// 任务浮窗读得到每一次发出去的原文。
@MainActor
struct TaskPromptTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 长按菜单_任务按频率排_危险项单独在最后_没有缩进与反缩进() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(CardMenu.sections(for: task) == [[.handToAgent, .start, .move, .untodo], [.trash]])

        try await store.setStatus(task.id, .inProgress)
        let started = try #require(try await store.card(task.id))
        #expect(CardMenu.sections(for: started) == [[.handToAgent, .backToTodo, .move, .untodo], [.trash]])
    }

    @Test func 长按菜单_灵感以要做打头_编辑页里不重复交给Agent() async throws {
        let idea = try await store.createCard(in: nil, body: "想法")
        #expect(CardMenu.sections(for: idea) == [[.todo, .handToAgent, .pin, .move], [.trash]])
        #expect(CardMenu.sections(for: idea, inEditor: true) == [[.todo, .pin, .move], [.trash]])
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

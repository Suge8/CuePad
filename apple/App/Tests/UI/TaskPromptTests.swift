import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务是一件要做成的事，要交给 Agent 的话是挂在它下面的提示词：长按菜单最多四项加删除（共用一处定义）；
/// 灵感是资料，它的主动作是挂到任务（成为提示词），交给 Agent 只在提示词上；任务行看得出有几条提示词、几条已回复，全部回复后行尾出现"完成"。
@MainActor
struct TaskPromptTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    @Test func 长按菜单_灵感是挂到任务设为任务移到项目归档_提示词才交给Agent() async throws {
        let idea = try await store.createCard(in: nil, body: "想法")
        #expect(CardMenu.sections(for: idea) == [[.attachToTask, .makeTask, .move, .archive], [.trash]])

        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        #expect(CardMenu.sections(for: prompt) == [[.handToAgent, .makeTask, .move, .archive], [.trash]])
    }

    @Test func 只有提示词能交给Agent_灵感与任务都不能() async throws {
        let idea = try await store.createCard(in: nil, body: "想法")
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        #expect(!CardMenu.handsToAgent(idea))
        #expect(!CardMenu.handsToAgent(task))
        #expect(CardMenu.handsToAgent(prompt))
    }

    @Test func 长按菜单_任务是完成或重新打开与归档_删除单独在最后() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(CardMenu.sections(for: task) == [[.complete, .archive], [.trash]])

        try await store.setStatus(task.id, .done)
        let done = try #require(try await store.card(task.id))
        #expect(CardMenu.sections(for: done) == [[.reopen, .archive], [.trash]])
    }

    @Test func 更多菜单_低频操作在任务页与纸页的更多里() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let sub = try await store.createTask("复现", under: task.id)
        #expect(CardMenu.more(for: task) == [[.move, .copy], [.makeIdea, .archive], [.trash]])
        // 子任务跟着上级走，不单独换项目
        #expect(CardMenu.more(for: sub) == [[.copy], [.makeIdea, .archive], [.trash]])

        let idea = try await store.createCard(in: nil, body: "想法")
        #expect(CardMenu.more(for: idea) == [[.attachToTask, .makeTask, .resource, .move, .copy], [.archive], [.trash]])
        try await store.updateCard(idea.id) { $0.isPinned = true }
        #expect(CardMenu.more(for: try #require(try await store.card(idea.id)))[0] == [.attachToTask, .makeTask, .unresource, .move, .copy])
        // 提示词已经挂在任务下：不再"挂到任务"
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        #expect(CardMenu.more(for: prompt) == [[.makeTask, .resource, .move, .copy], [.archive], [.trash]])
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

    @Test func 任务行写着几条提示词几条已回复_全部回复后出现完成() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        #expect(PromptTally(try await store.childMarks()[task.id]).text == nil)

        let first = try await store.createCard(body: "先复现", under: task.id)
        let second = try await store.createCard(body: "再改排序", under: task.id)
        _ = try await store.createTask("补用例", under: task.id)
        var tally = PromptTally(try await store.childMarks()[task.id])
        #expect(tally.text == "2 条提示词")
        #expect(!tally.suggestsDone(task))

        try await reply(to: first)
        tally = PromptTally(try await store.childMarks()[task.id])
        #expect(tally.text == "2 条提示词 · 1 已回复")
        #expect(tally.heading == "2 · 1 已回复")
        #expect(!tally.suggestsDone(task))

        try await reply(to: second)
        tally = PromptTally(try await store.childMarks()[task.id])
        #expect(tally.text == "2 条提示词 · 全部已回复")
        #expect(tally.suggestsDone(task))
        // 任务不自动完成：由用户确认
        #expect(try await store.card(task.id)?.status == .inProgress)
        try await store.setStatus(task.id, .done)
        #expect(!tally.suggestsDone(try #require(try await store.card(task.id))))
    }

    @Test func 提示词卡片_没发过_交给会话后处理中_那一轮做完是已回复() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        #expect(try await state(of: prompt, in: task) == "unsent")

        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        try await enter(.thinking, recorder)
        #expect(try await state(of: prompt, in: task) == "working atlas")

        try await enter(.settled, recorder)
        #expect(try await state(of: prompt, in: task) == "replied atlas")
    }

    @Test func 手机重发还在路上_卡片是正在发给Agent而不是已回复() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        try await reply(to: prompt)
        #expect(try await state(of: prompt, in: task) == "replied atlas")

        _ = try await store.requestDelivery("先复现，这次带上日志", to: atlas, on: "mac-a", card: prompt.id)
        #expect(try await state(of: prompt, in: task) == "working atlas")
        let detail = try await TaskDetail.read(task.id, from: store)
        guard case .working(let item) = detail.state(of: prompt) else { return }
        #expect(rig.services.settings.shown(item).presence == "正在发给 Agent")
    }

    @Test func 会话没回复就结束了_卡片是会话已结束_不算全部已回复() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        try await enter(.thinking, recorder)
        try await Task.sleep(for: .milliseconds(5))
        try await recorder.end(sessionID: "s1")

        #expect(try await state(of: prompt, in: task) == "ended atlas")
        let tally = PromptTally(try await store.childMarks()[task.id])
        #expect(tally.text == "1 条提示词")
        #expect(!tally.suggestsDone(try #require(try await store.card(task.id))))
    }

    @Test func 任务页读到提示词与子任务_各自按放的顺序() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let first = try await store.createCard(body: "先复现", under: task.id)
        let sub = try await store.createTask("补用例", under: task.id)
        let second = try await store.createCard(body: "再改排序", under: task.id)

        let detail = try await TaskDetail.read(task.id, from: store)
        #expect(detail.prompts.map(\.id) == [first.id, second.id])
        #expect(detail.subtasks.map(\.id) == [sub.id])
    }

    @Test func 一页只有一颗靛青的交给Agent_落在第一条还没发的提示词上() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let first = try await store.createCard(body: "先复现", under: task.id)
        let second = try await store.createCard(body: "再改排序", under: task.id)
        _ = try await store.createCard(body: "补用例", under: task.id)
        #expect(try await TaskDetail.read(task.id, from: store).primaryPrompt == first.id)

        try await reply(to: first)
        #expect(try await TaskDetail.read(task.id, from: store).primaryPrompt == second.id)
    }

    /// 交给 atlas，它这一轮做完。
    private func reply(to prompt: Card) async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        try await enter(.thinking, recorder)
        try await enter(.settled, recorder)
    }

    /// 会话 atlas 进入 `state`（时刻晚于刚才的发出：按毫秒比先后）。
    private func enter(_ state: PiWorkState, _ recorder: PiStateRecorder) async throws {
        try await Task.sleep(for: .milliseconds(5))
        _ = try await recorder.update(sessionID: "s1", state: state, title: "atlas", times: PiTimes(stateSince: .now, busySince: nil))
    }

    private func state(of prompt: Card, in task: Card) async throws -> String {
        let detail = try await TaskDetail.read(task.id, from: store)
        switch detail.state(of: prompt) {
        case .unsent: return "unsent"
        case .launching: return "launching"
        case .working(let item): return "working \(item.state.title)"
        case .ended(let item): return "ended \(item.state.title)"
        case .replied(let item): return "replied \(item?.state.title ?? "")"
        }
    }
}

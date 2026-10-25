import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 任务优先的主动线，按用户走的路写：建任务 → 开始把正文交给 Agent（话在路上、没送到可重发、送达后正文留着）→ 完成并归档；中途撤销。
/// 规则单测（行的状态怎么推）都从这些动作里走一遍，不单独测；各处写的任务数见 `TaskCountTests`，整理层级见 `TaskOutlineTests`。
struct TaskFlowTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    // MARK: 任务走完全程

    @Test func 灵感接进任务_开始把正文交给Agent_没送到在会话里看_送达后正文留着_完成并归档() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let created = try await store.createTask("修乱序", in: project.id)
        let idea = try await store.createCard(in: project.id, body: "日志在 logs/0918.txt")
        let workspace = Workspace(services: rig.services)

        // 灵感拖到任务上：接在正文后面，灵感进回收站，不拆出别的卡
        try await workspace.mergeIdea(idea.id, into: created.id)
        let task = try #require(try await store.card(created.id))
        #expect(task.title == "修乱序" && task.rest == "日志在 logs/0918.txt")
        #expect(try await store.trashedCards().map(\.id) == [idea.id])
        #expect(try await store.children(of: task.id).isEmpty)
        #expect(try await next(task) == .start(leaf: task))

        // 开始：正文连同标题交出去；话在路上、没送到都看会话那一格，不再给"开始"
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "atlas")
        let delivers = Mutex(false)
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store, atlas] request in
            guard delivers.withLock({ $0 }) else { return .failed(.verbatim("会话在送达前关掉了")) }
            _ = try? await store.recordSend(request.content, to: atlas, card: request.cardID)
            return .succeeded
        }
        let request = try await store.requestDelivery(Outgoing.text(of: task), to: atlas, on: "mac-a", card: task.id)
        guard case .agent(let sending, _) = try await next(task) else { throw Unexpected.next }
        #expect(sending.isRunning && sending.undelivered == nil)
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.status }) { $0 == .known(.failed) }
        guard case .agent(let failed, _) = try await next(task) else { throw Unexpected.next }
        #expect(failed.undelivered != nil)

        // 重发送达：任务进行中并记着会话，正文留在任务上
        delivers.withLock { $0 = true }
        try await store.requestDelivery(Outgoing.text(of: task), to: atlas, on: "mac-a", card: task.id)
        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "s1" }
        await executor.stop()
        let started = try #require(try await store.card(task.id))
        #expect(started.status == .inProgress && started.body == "修乱序\n\n日志在 logs/0918.txt")

        // 任务不自动完成；用户勾选，提示里给归档
        try await workspace.toggle(task.id)
        #expect(workspace.notice?.text == "已完成")
        let archive = try #require(workspace.notice?.action)
        #expect(archive.title == "归档")
        try await archive.run()
        #expect(try await store.card(task.id)?.archivedAt != nil)
    }

    // MARK: 会话与任务

    #if os(macOS)
    @Test func 一个会话绑两件事_绑定不发正文_都做完才结束会话() async throws {
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let first = try await store.createTask("复现乱序\n先复现，别改代码", in: project.id)
        let second = try await store.createTask("补重连用例", in: project.id)
        try await PiStateRecorder(store: store, hostID: "mac-other").update(sessionID: "s1", state: .thinking, title: "atlas")
        rig.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())

        try await store.bindSession("s1", to: first.id)
        try await store.bindSession("s1", to: second.id)
        #expect(rig.services.settings.replyDraft(for: PiSessionState.recordID(sessionID: "s1")).isEmpty(accepting: .images))
        #expect(try await store.deliveryRequests().isEmpty)
        #expect(try await store.card(first.id)?.rest == "先复现，别改代码")
        #expect(try await Set(store.tasks(boundTo: "s1").map(\.task.id)) == [first.id, second.id])

        let ends = { [store] in try await store.deliveryRequests().filter { $0.mode == .known(.end) }.map(\.target.ref) }
        try await workspace.toggle(first.id)
        #expect(try await ends().isEmpty)
        try await workspace.toggle(second.id)
        #expect(try await ends() == ["s1"])
    }

    /// 分步做一件事（与 Cue 同一条规则）：上一步做完、下一步还没开工时会话留着；下一步"开始"接着用它——只发这一步的标题与正文，不开新会话；
    /// 要新会话就在"绑定会话"里选"开新会话"：第一句先带顶层任务的标题与正文作背景，再接这一步的；最后一步做完，会话才结束。
    @Test func 分步做_下一步接着用上一步的会话_最后一步做完才结束() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("加语言参数\n命令行要能切中英文", in: project.id)
        let first = try await store.createTask("加 --lang", under: task.id)
        let second = try await store.createTask("写 README", under: task.id)
        let third = try await store.createTask("发版\n打 tag 再发", under: task.id)
        try await PiStateRecorder(store: store, hostID: "mac-other").update(sessionID: "s1", state: .settled, title: "atlas")
        rig.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
        try await store.bindSession("s1", to: first.id)
        let requests = { [store] (mode: DeliveryMode) in try await store.deliveryRequests().filter { $0.mode == .known(mode) } }

        try await workspace.toggle(first.id)
        #expect(try await requests(.end).isEmpty)

        try await store.updateCard(second.id) { $0.rest = "照 --lang 的用法写 README" }
        workspace.handOff(try #require(try await store.card(second.id)))
        let sent = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.send) } }) { $0 != nil }
        #expect(sent?.target.ref == "s1" && sent?.content == "写 README\n照 --lang 的用法写 README")
        #expect(try await requests(.start).isEmpty)

        workspace.startFresh(third)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        #expect(launch?.cardID == third.id && launch?.launch?.project == project.id)
        #expect(launch?.launch?.prompt == "加语言参数\n命令行要能切中英文\n\n发版\n打 tag 再发")
        _ = try await store.withdrawDelivery(try #require(launch).id)  // 本机不执行：开新会话的去向核对完即可

        // 会话所在的 Mac 送到：记下这次发送，这一步绑上会话
        let executor = DeliveryExecutor(store: store, hostID: "mac-other", onIssue: { Issue.record("\($0)") }) { [store] request in
            _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID)
            return .succeeded
        }
        try await executor.start()
        _ = try await eventually(store, { try $0.card(second.id)?.piSessionID }) { $0 == "s1" }
        await executor.stop()
        try await workspace.toggle(second.id)
        #expect(try await requests(.end).isEmpty)  // "发版"还没开工，默认接着用它
        try await workspace.toggle(third.id)
        #expect(try await requests(.end).map(\.target.ref) == ["s1"])
    }

    /// 行尾那一格是"开始"；点它开一个会话，正在开时不再给"开始"，没开成不算交给过，重新给"开始"。
    @Test func 点开始交给Agent_正在开时不再给开始_没开成重新给() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("修发言乱序", in: project.id)
        #expect(try await next(task) == .start(leaf: task))

        workspace.handOff(task)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        let request = try #require(launch)
        #expect(request.launch?.project == project.id)
        #expect(try await next(task) == nil)

        let executor = DeliveryExecutor(store: store, hostID: request.hostID, onIssue: { Issue.record("\($0)") }) { _ in .failed(.verbatim("这台 Mac 上开不了会话")) }
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.status }) { $0 == .known(.failed) }
        await executor.stop()
        #expect(try await next(task) == .start(leaf: task))
    }
    #endif

    // MARK: 撤销与批量

    @Test func 灵感接进任务_删除_都能撤销_勾选以最新状态为准() async throws {
        let workspace = Workspace(services: rig.services)
        let body = "上线前检查\n把 changelog 过一遍"
        let check = try await store.createTask(body)
        let crash = try await store.createCard(body: "看下 {{平台}} 崩溃率，{{阈值}}")
        try await store.updateCard(crash.id) { $0.variableValues = ["平台": "iOS"] }
        try await workspace.mergeIdea(crash.id, into: check.id)
        #expect(workspace.notice?.text == "已接到「上线前检查」的正文后面")
        // 灵感填好的变量随正文接过去，没填的留着占位符
        #expect(try await store.card(check.id)?.body == body + "\n\n看下 iOS 崩溃率，{{阈值}}")
        try await #require(workspace.notice?.action).run()
        #expect(try await store.card(check.id)?.body == body)
        #expect(try await store.cards(in: Project.defaultID).map(\.id) == [crash.id])

        let idea = try await store.createCard(body: "续费域名")
        try await workspace.trash(idea.id)
        #expect(workspace.notice?.text == "已删除")
        #expect(try await store.trashedCards().map(\.id) == [idea.id])
        try await #require(workspace.notice?.action).run()
        #expect(try await store.trashedCards().isEmpty)

        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let stale = try await store.createTask("续费域名")
        try await workspace.toggle(stale.id)
        try await workspace.toggle(stale.id)  // 手里的副本已过时：切换以 Store 当前状态为准
        #expect(try await store.card(stale.id)?.status == .todo)

        workspace.convertToTasks("- 写发布说明\n\n- 更新截图", in: project.id)
        try await eventually("转好任务") { workspace.notice?.text == "已转为 2 个任务" }
        #expect(try await store.tasks(.todo).flatMap(\.tasks).filter { $0.projectID == project.id }.map(\.body) == ["写发布说明", "更新截图"])
    }

    // MARK: 共用的小件

    private enum Unexpected: Error { case next }

    /// 任务行"下一步"那一格（叶子，与行上读的同一份交给的会话）。
    private func next(_ task: Card) async throws -> TaskNext? {
        let agents = try await AgentLinks.read(from: store)
        return Workspace(services: rig.services).next(for: task, in: agents, steps: nil)
    }
}

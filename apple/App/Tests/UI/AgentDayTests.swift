import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// Agent 页上看到的会话，按它一天里的样子写：新会话、做完一轮没看、看过、有草稿；发话后发送中、排队、没能送达（留到看过为止）、
/// 唤醒已结束的会话；改名与结束会话（手机请 Mac 做，Mac 写回结果）；列表的先后与筛选。行的文字与图形怎么拼不单独测，从这些状态里读。
@MainActor
struct AgentDayTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }

    private func item(_ sessionID: String) async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery(limit: .max)).items.first { $0.state.sessionID == sessionID })
    }

    private func label(_ sessionID: String) async throws -> String { settings.shown(try await item(sessionID)).label }

    @discardableResult
    private func say(_ text: String, to sessionID: String, mode: DeliveryMode = .send) async throws -> DeliveryRequest {
        let state = try await item(sessionID).state
        return try await store.requestDelivery(text, to: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, mode: mode)
    }

    /// 那台 Mac 的执行器领到请求后按 `outcome` 写回，等到这条请求有结果。
    private func macAnswers(_ request: DeliveryRequest, host: String, _ outcome: DeliveryOutcome) async throws {
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { Issue.record("执行器意外上报：\($0)") }) { _ in outcome }
        try await executor.start()
        for try await open in store.observe({ try $0.deliveryRequest(request.id)?.isOpen }) where open == false { break }
        await executor.stop()
    }

    @Test func 一个会话一天里_新会话_有新回复_看过_草稿_发话_排队() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .settled, title: "atlas")
        #expect(try await label("atlas") == "新会话")  // 终端里刚开、还没有任何一轮：不是"该你了"

        try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [], recap: PiRecap(lastPrompt: "跑一下测试", lastReply: "全部通过。共 214 个。")))
        let done = try await item("atlas")
        #expect(settings.shown(done).label == "有新回复")
        settings.markSeen(done.state, at: .now.addingTimeInterval(1))
        #expect(try await label("atlas") == "该你了")
        #expect(!app.relaunch().settings.isUnread(done.state))  // 看过记在本机偏好，退出再回来还算看过

        // 回复框里没发的草稿写在第三行；清空后回到最后的回答
        settings.setReplyDraft(ComposerDraft(text: "改完再跑一遍\n顺便看看覆盖率"), for: done.state.id)
        #expect(PiRowLine.of(done.state, draft: settings.draftPreview(for: done.state.id), end: nil) == .draft("改完再跑一遍"))
        settings.setReplyDraft(ComposerDraft(text: "  \n"), for: done.state.id)
        #expect(PiRowLine.of(done.state, draft: settings.draftPreview(for: done.state.id), end: nil) == .progress("全部通过。"))

        // 发话：当场是"发送中"，会话进入处理中后让位给它自己的状态；它在跑时排队的话只是个小标记
        try await say("看看 scheduler", to: "atlas")
        #expect(try await label("atlas") == "发送中")
        try await recorder.update(sessionID: "atlas", state: .thinking, title: "atlas")
        #expect(try await label("atlas") == "思考中")
        try await recorder.update(sessionID: "gamma", state: .tool, title: "gamma")
        try await say("改完再看看登录回调", to: "gamma", mode: .followUp)
        let queued = settings.shown(try await item("gamma"))
        #expect(queued.label == "运行工具")
        #expect(queued.note == "你的话排队中")
    }

    @Test func 没能送达留到看过为止_发给已结束的会话是正在唤醒() async throws {
        let beta = PiStateRecorder(store: store, hostID: "mac-b")
        try await beta.update(sessionID: "beta", state: .settled, title: "beta")
        let lost = try await say("备份一下线上库", to: "beta")
        try await macAnswers(lost, host: "mac-b", .failed("Pi 已经退出"))
        try await Task.sleep(for: .milliseconds(5))
        try await beta.update(sessionID: "beta", state: .thinking, title: "beta")
        try await beta.update(sessionID: "beta", state: .settled, title: "beta")
        #expect(try await label("beta") == "没能送达")  // 会话之后动过也不消失
        settings.markSeen(try await item("beta").state, at: .now.addingTimeInterval(1))
        #expect(try await label("beta") != "没能送达")

        try await PiStateRecorder(store: store, hostID: "mac-c").update(sessionID: "gone", state: .ended, title: "gone")
        try await say("接着做", to: "gone")
        #expect(try await label("gone") == "正在唤醒")
    }

    @Test func 改会话名_在路上是新名_没改成回到旧名并写原因_Pi改好以会话记录为准() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-d")
        try await recorder.update(sessionID: "delta", state: .settled, title: "delta")
        func title() async throws -> String {
            let item = try await item("delta")
            return PiRename.title(of: item.state, request: item.rename)
        }

        let request = try await app.services.rename(try await item("delta").state, to: "  排队调度\n")
        #expect(request.config == PiConfig(name: "排队调度") && PiChat.outgoing([request], messages: []).isEmpty)  // 不算发给会话的话
        #expect(try await title() == "排队调度")
        #expect(try await item("delta").delivery == nil)

        try await macAnswers(request, host: "mac-d", .failed("Pi 已经退出"))
        let failed = try await item("delta")
        #expect(PiRename.title(of: failed.state, request: failed.rename) == "delta")
        #expect(PiRowLine.of(failed.state, draft: nil, end: nil, failure: PiRename.failure(failed.rename, seen: nil)) == .failed("没能改名：Pi 已经退出"))
        #expect(PiRename.failure(failed.rename, seen: .now.addingTimeInterval(1)) == nil)

        let again = try await app.services.rename(failed.state, to: "排队调度")
        try await macAnswers(again, host: "mac-d", .succeeded)
        try await Task.sleep(for: .milliseconds(5))
        try await recorder.update(sessionID: "delta", state: .settled, title: "排队调度")
        #expect(try await title() == "排队调度")
        try await recorder.update(sessionID: "delta", state: .settled, title: "调度")  // 之后在终端里又改了名：以 Pi 为准
        #expect(try await title() == "调度")
    }

    @Test func 列表先后_等你确认_出错_工作中_空闲_已结束_可按项目与文字筛() async throws {
        let table = try await store.createProject(name: "圆桌", color: "#000000")
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "done", state: .ended, title: "done")
        try await recorder.update(sessionID: "idle", state: .settled, title: "idle")
        try await recorder.update(sessionID: "busy", state: .tool, detail: "bash", title: "busy", projectID: table.id)
        try await recorder.update(sessionID: "ask", state: .waitingForUser, detail: "要覆盖吗？", title: "ask")
        try await recorder.update(sessionID: "broken", state: .error, title: "broken")

        let all = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, from: store)
        #expect(all.now.map(\.state.sessionID) == ["ask", "broken", "busy", "idle"])
        #expect(all.ended.map(\.state.sessionID) == ["done"])
        let inTable = try await PiSessionList.read(text: "", project: table.id, historyLimit: PiSessionList.pageSize, from: store)
        #expect(inTable.now.map(\.state.sessionID) == ["busy"])
        let found = try await PiSessionList.read(text: "bro", historyLimit: PiSessionList.pageSize, from: store)
        #expect(found.now.map(\.state.sessionID) == ["broken"])
    }

    #if os(iOS)
    /// 结束会话：进度只来自发给会话的结束请求；还在路上时再点不发第二条；没能结束写 Mac 给的原因；结束了进历史、不留进度。
    @Test func 结束会话_在路上不重复_没结束写原因_结束了进历史() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "deploy", state: .waitingForUser, title: "deploy")
        let session = try await item("deploy").state
        let workspace = Workspace(services: app.services)
        func list() async throws -> PiSessionList { try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, from: store) }

        await workspace.end(session)
        await workspace.end(session)
        let ends = try await store.deliveryRequests(toSession: "deploy").filter { $0.mode == .known(.end) }
        #expect(ends.count == 1)
        #expect(try await list().ends[session.id]?.isOpen == true)

        try await macAnswers(ends[0], host: "mac-a", .failed("会话没有按时结束，可能还在等你在终端里处理"))
        #expect(try await list().ends[session.id]?.failure == "会话没有按时结束，可能还在等你在终端里处理")

        await workspace.end(session)
        let retry = try #require(try await store.deliveryRequests(toSession: "deploy").last { $0.mode == .known(.end) })
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "deploy", state: .ended, title: "deploy")
        try await macAnswers(retry, host: "mac-a", .succeeded)
        let after = try await list()
        #expect(!after.now.map(\.id).contains(session.id) && after.ended.map(\.id).contains(session.id) && after.ends[session.id] == nil)
    }

    /// Agent 页的项目筛选：标签页选的记在本机、重开后还筛着；从项目页进来先筛该项目、在那里换的不记；记住的项目进了回收站回到全部。
    @Test func Agent页筛选_标签页记住_推入页不记_项目进回收站回到全部() async throws {
        let table = try await store.createProject(name: "圆桌", color: "#000000")
        let site = try await store.createProject(name: "个人网站", color: "#000000")
        let suite = "agent-filter-\(UUID())"
        func navigation() -> Navigation { Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:])) }
        func catalog(_ projects: [Project]) -> ProjectCatalog {
            ProjectCatalog(projects: projects, cardCounts: [:], taskCounts: [:], directories: [:], bindings: [])
        }
        let projects = catalog([table, site])
        navigation().chooseAgentFilter(table.id)
        let nav = navigation()
        #expect(nav.agentFilter(catalog: projects) == table.id)  // 重开后还筛着

        var pushed = AgentFilter(entered: site.id)
        #expect(pushed.current(in: nav, catalog: projects) == site.id)
        pushed.choose(nil, in: nav)
        #expect(pushed.current(in: nav, catalog: projects) == nil)
        #expect(AgentFilter(entered: nil).current(in: nav, catalog: projects) == table.id)  // 标签页的筛选没被推入页改动

        #expect(nav.agentFilter(catalog: catalog([])) == nil)  // 记住的项目进了回收站：回到全部
    }
    #endif
}

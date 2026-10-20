#if os(macOS)
import CuePi
#endif
import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// Agent 页上看到的会话，按它一天里的样子写：新会话、做完一轮没看、看过、有草稿；发话后发送中、没能送达（留到看过为止）、
/// 唤醒已结束的会话；改名与结束会话（手机请 Mac 做，Mac 写回结果）；列表的先后与筛选。行的文字与图形怎么拼不单独测，从这些状态里读。
struct AgentDayTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }
    var workspace: Workspace { Workspace(services: app.services) }

    private func item(_ sessionID: String) async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery(limit: .max)).items.first { $0.state.sessionID == sessionID })
    }

    private func label(_ sessionID: String) async throws -> String { workspace.shown(try await item(sessionID)).label }

    /// 行上状态词后面的短词（"有草稿""没能改名"……）。
    private func note(_ item: PiSessionListItem) -> PiRowFacts.Note? {
        settings.facts(item.state, shown: workspace.shown(item), end: nil, rename: item.rename, at: .always()).note
    }

    @discardableResult
    private func say(_ text: String, to sessionID: String) async throws -> DeliveryRequest {
        let state = try await item(sessionID).state
        return try await store.requestDelivery(text, to: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID)
    }

    /// 那台 Mac 的执行器领到请求后按 `outcome` 写回，等到这条请求有结果。
    private func macAnswers(_ request: DeliveryRequest, host: String, _ outcome: DeliveryOutcome) async throws {
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { Issue.record("执行器意外上报：\($0)") }) { _ in outcome }
        try await executor.start()
        for try await open in store.observe({ try $0.deliveryRequest(request.id)?.isOpen }) where open == false { break }
        await executor.stop()
    }

    /// 在等你时按它问的是什么说：要你填一段文字是"等你回答"，是或否、从选项里选是"等你确认"。
    @Test func 文字题等你回答_确认与选择题等你确认() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        let questions: [(String, PiQuestionKind)] = [("words", .text), ("yesno", .confirm), ("pick", .select)]
        for (id, kind) in questions {
            try await recorder.update(
                sessionID: id, state: .waitingForUser, title: id,
                question: PiQuestion(promptID: "p", kind: .known(kind), text: "问题", options: kind == .select ? ["A", "B"] : []))
        }

        #expect(try await label("words") == "等你回答")
        #expect(try await label("yesno") == "等你确认")
        #expect(try await label("pick") == "等你确认")
    }

    @Test func 一个会话一天里_新会话_有新回复_看过_草稿_发话() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .settled, title: "atlas")
        #expect(try await label("atlas") == "新会话")  // 终端里刚开、还没有任何一轮：不是"该你了"

        try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [], recap: PiRecap(lastPrompt: "跑一下测试", lastReply: "全部通过。共 214 个。")))
        let done = try await item("atlas")
        #expect(workspace.shown(done).label == "有新回复")
        settings.markSeen(done.state, at: .now.addingTimeInterval(1))
        #expect(try await label("atlas") == "该你了")
        #expect(!app.relaunch().settings.isUnread(done.state))  // 看过记在本机偏好，退出再回来还算看过

        // 回复框里没发的草稿：行上写"有草稿"；只剩空白不算
        settings.setReplyDraft(ComposerDraft(text: "改完再跑一遍\n顺便看看覆盖率"), for: done.state.id)
        #expect(note(done) == .draft)
        settings.setReplyDraft(ComposerDraft(text: "  \n"), for: done.state.id)
        #expect(note(done) == nil)

        // 发话：当场是"发送中"，会话进入处理中后让位给它自己的状态；它在跑时还在路上的话只是个小标记
        try await say("看看 scheduler", to: "atlas")
        #expect(try await label("atlas") == "发送中")
        try await recorder.update(sessionID: "atlas", state: .thinking, title: "atlas")
        #expect(try await label("atlas") == "思考中")
        try await recorder.update(sessionID: "gamma", state: .tool, title: "gamma")
        try await say("改完再看看登录回调", to: "gamma")
        let busy = workspace.shown(try await item("gamma"))
        #expect(busy.label == "运行工具")
        #expect(busy.note == "你的话发送中")
    }

    #if os(macOS)
    /// 这台 Mac 上它正在出字：会话行与会话页顶栏同一个说法"输出中"，说完（正在说的话清掉）回到"思考中"。
    @Test func 正在出字时列表与顶栏都写输出中() async throws {
        let ext = try await app.host.connect("atlas", cwd: "/work/atlas", busy: true)
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "atlas", state: .thinking, title: "atlas")

        app.services.pi.setDraft(ext.id, PiDraft(text: "先看", since: .now))
        let row = try await item("atlas")
        #expect(workspace.shown(row).label == "输出中")
        #expect(workspace.shownInHeader(row.state).label == "输出中")

        app.services.pi.setDraft(ext.id, nil)
        #expect(workspace.shown(row).label == "思考中")
    }
    #endif

    @Test func 没能送达留到看过为止_发给已结束的会话是正在唤醒_列在现在() async throws {
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
        // 唤醒中就列在"现在"（侧栏的在做、Agent 页），不在历史
        app.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
        #expect(workspace.liveWork.rows.contains { $0.sessionID == "gone" } && workspace.liveWork.running == 1)  // 区头数它在跑
        let list = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(list.now.contains { $0.state.sessionID == "gone" } && !list.historyRuns.flatMap(\.items).contains { $0.state.sessionID == "gone" })
    }

    @Test func 改会话名_在路上是新名_没改成回到旧名并写没能改名_Pi改好以会话记录为准() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-d")
        try await recorder.update(sessionID: "delta", state: .settled, title: "delta")
        func title() async throws -> String {
            let item = try await item("delta")
            return PiRename.title(of: item.state, request: item.rename, at: .always())
        }

        let request = try await app.services.rename(try await item("delta").state, to: "  排队调度\n")
        #expect(request.config == PiConfig(name: "排队调度") && PiChat.outgoing([request], messages: []).isEmpty)  // 不算发给会话的话
        #expect(try await title() == "排队调度")
        #expect(try await item("delta").delivery == nil)

        try await macAnswers(request, host: "mac-d", .failed("Pi 已经退出"))
        let failed = try await item("delta")
        #expect(PiRename.title(of: failed.state, request: failed.rename, at: .always()) == "delta")
        #expect(note(failed) == .renameFailed)
        settings.markSeen(failed.state, at: .now.addingTimeInterval(1))
        #expect(note(failed) == nil)  // 看过就不再写

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

        let all = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(all.now.map(\.state.sessionID) == ["ask", "broken", "busy", "idle"])
        #expect(all.ended.map(\.state.sessionID) == ["done"])
        let inTable = try await PiSessionList.read(text: "", project: table.id, historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(inTable.now.map(\.state.sessionID) == ["busy"])
        let found = try await PiSessionList.read(text: "bro", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(found.now.map(\.state.sessionID) == ["broken"])
    }

    #if os(iOS)
    /// 结束会话：进度只来自发给会话的结束请求；还在路上时再点不发第二条；没能结束写 Mac 给的原因；结束了进历史、不留进度。
    @Test func 结束会话_在路上不重复_没结束写原因_结束了进历史() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "deploy", state: .waitingForUser, title: "deploy")
        let session = try await item("deploy").state
        let workspace = Workspace(services: app.services)
        func list() async throws -> PiSessionList { try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store) }

        await workspace.end(session)
        await workspace.end(session)
        let ends = try await store.deliveryRequests(toSession: "deploy").filter { $0.mode == .known(.end) }
        #expect(ends.count == 1)
        #expect(try await list().ends[session.id] == .sending)

        try await macAnswers(ends[0], host: "mac-a", .failed("会话没有按时结束，可能还在等你在终端里处理"))
        #expect(try await list().ends[session.id]?.failure == .reported("会话没有按时结束，可能还在等你在终端里处理"))

        await workspace.end(session)
        let retry = try #require(try await store.deliveryRequests(toSession: "deploy").last { $0.mode == .known(.end) })
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "deploy", state: .ended, title: "deploy")
        try await macAnswers(retry, host: "mac-a", .succeeded)
        let after = try await list()
        #expect(!after.now.map(\.id).contains(session.id) && after.ended.map(\.id).contains(session.id) && after.ends[session.id] == nil)
    }

    #endif
}

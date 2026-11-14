#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
@testable import CueBridge
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SessionTaskTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    @Test func 不经任务开的会话_不长任务_Cue的信封里看得到_能对它说话_也能为它建任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await enableCue()
        try services.reconcileLaunch()  // Mac 启动
        var session = CueBridge.Session(
            id: "s1.100", sessionID: "s1", agent: .pi, sessionFile: URL(filePath: "/tmp/never-\(UUID().uuidString).jsonl"), pid: 100,
            cwd: URL(filePath: "/work/x", directoryHint: .isDirectory), 
            state: .settled, stateSince: .now)
        session.name = "修登录"
        try await bridge(.appeared(session))

        let empty = try await TaskBoard.read(from: store)
        #expect(empty.todo.isEmpty && empty.advancing.map(\.id) == ["session/s1"])
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: .now, projects: [], changes: [], board: try await store.cueBoard(), waiting: [],
            wake: .idle))
        #expect(envelope.contains("在做 1 件：\n- 会话「修登录」（s1） · 空闲"))

        let cue = CueTools(store: store, wait: 0)
        let said = try #require(await cue.call("task", ["action": "say", "session": "修登录", "text": "补上登录的测试"]))
        #expect(!said.isError && said.text.contains("会话「修登录」"))
        // 有的模型把没用到的参数填成空值、把会话的编号写进 task：照样送到
        let filled = try #require(await cue.call("task", ["action": "say", "task": "", "session": "修登录", "model": "", "effort": "", "text": "再跑一遍"]))
        #expect(!filled.isError, "\(filled.text)")
        let swapped = try #require(await cue.call("task", ["action": "say", "task": "s1", "text": "跑完告诉我"]))
        #expect(!swapped.isError, "\(swapped.text)")
        #expect(try await store.deliveryRequests(toSession: "s1").map(\.content) == ["补上登录的测试", "再跑一遍", "跑完告诉我"])

        let added = try #require(await cue.call("task", ["action": "add", "title": "修好登录", "session": "s1"]))
        #expect(!added.isError)
        let row = try #require(try await TaskBoard.read(from: store).advancing.first?.item)
        #expect(row.task.title == "修好登录" && row.project?.id == project.id && row.task.piSessionID == "s1")
        #expect(try await store.cueBoard().sessions.isEmpty)
    }

    @Test func 对已完成任务的会话说话_你的话让它回到进行中_Cue的话不改() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        let recorder = StateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let workspace = Workspace(services: services)
        try await store.bindSession("s1", to: task.id)
        try await workspace.complete(task.id)
        #expect(try await store.card(task.id)?.status == .done)
        let executor = DeliveryExecutor(store: store, hostID: services.hostID, onIssue: { Issue.record("\($0)") }) { _, _ in .succeeded }
        try await executor.start()
        defer { await executor.stop() }

        try await reply("登录后还是白屏", to: "s1", in: workspace)
        let sent = try #require(try await store.deliveryRequests(toSession: "s1").last)
        #expect(sent.mode == .known(.send))
        #expect(try await store.outcome(of: sent).status == .known(.succeeded))
        #expect(try await store.card(task.id)?.status == .inProgress)

        let question = Question(promptID: "p1", kind: .select, text: "旧数据怎么办？", options: ["覆盖", "跳过"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        try await reply("2", to: "s1", in: workspace)
        #expect(try await store.deliveryRequests(toSession: "s1").last?.answer == Answer(promptID: "p1", value: .option("跳过")))
        try await workspace.complete(task.id)

        let cue = CueTools(store: store, wait: 0)
        let answered = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "覆盖"]))
        #expect(!answered.isError && answered.text.contains("回答"))
        let answer = try #require(try await store.deliveryRequests(toSession: "s1").last)
        #expect(answer.answer == Answer(promptID: "p1", value: .option("覆盖")))
        #expect(try await store.outcome(of: answer).status == .known(.succeeded))
        #expect(try await store.card(task.id)?.status == .done)

        let reopened = try #require(await cue.call("task", ["action": "edit", "task": task.id.uuidString, "reopen": true]))
        #expect(!reopened.isError)
        #expect(try await store.card(task.id)?.status == .inProgress)  // 绑过会话就是开始过
        let again = try #require(await cue.call("task", ["action": "edit", "task": task.id.uuidString, "reopen": true]))
        #expect(again.isError)

        try await workspace.complete(task.id)
        _ = try await store.createTask("补测试", under: task.id)
        #expect(try await store.card(task.id)?.status == .inProgress)
    }

    @Test func 已完成的事的会话还活着_算在做_Cue在它上面另建任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await enableCue()
        let old = try await store.createTask("修登录", in: project.id)
        let recorder = StateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录", projectID: project.id)
        let workspace = Workspace(services: services)
        try await store.bindSession("s1", to: old.id)
        let mark = try await store.lastWrite()
        try await recorder.update(sessionID: "s1", state: .thinking, turnStartedAt: .now)
        try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: Recap(lastPrompt: "修登录", lastReply: "修好了", answeredAt: .now)))
        try await recorder.update(sessionID: "s1", state: .settled)
        try await workspace.complete(old.id)
        #expect(try await store.cueChanges(after: CueMarks(mark)).filter { $0.kind == .settled }.map(\.task?.id) == [old.id])

        #expect(try await store.cueBoard().sessions.isEmpty, "随完成的事收起")
        // 再有动静：时刻显式排在完成之后（收起按时刻严格先后判定，不靠真实时钟走过一毫秒）
        let later = try #require(try await store.card(old.id)?.completedAt).addingTimeInterval(1)
        try await recorder.update(sessionID: "s1", state: .thinking, times: SessionTimes(stateSince: later, busySince: later))
        try await recorder.update(sessionID: "s1", state: .settled, times: SessionTimes(stateSince: later.addingTimeInterval(1), busySince: nil))
        let board = try await store.cueBoard()
        #expect(board.sessions.map(\.sessionID) == ["s1"])
        let stepped = try await store.createTask("加语言参数", in: project.id)
        let first = try await store.createTask("加 --lang", under: stepped.id)
        let second = try await store.createTask("写 README", under: stepped.id)
        try await recorder.update(sessionID: "s2", state: .settled, title: "加 --lang", projectID: project.id)
        try await store.bindSession("s2", to: first.id)
        try await workspace.complete(first.id)
        try await workspace.complete(second.id)
        try await workspace.complete(stepped.id)
        let cue = CueTools(store: store, wait: 0)
        let peek = try #require(await cue.call("task", ["action": "peek"]))
        #expect(peek.text.contains("- 会话「修登录」（s1） · 空闲"))
        #expect(peek.text.contains("最近完成的") && peek.text.contains("- 修登录（\(old.id.shortID)） · 会话「修登录」（s1） · 空闲"))
        #expect(peek.text.contains("- 加语言参数（\(stepped.id.shortID)） · 会话「加 --lang」（s2） · 空闲"))

        let added = try #require(await cue.call("task", ["action": "add", "title": "补注册页", "session": "s1"]))
        #expect(!added.isError)
        let fresh = try #require(try await TaskBoard.read(from: store).advancing.first?.item?.task)
        #expect(fresh.title == "补注册页" && fresh.piSessionID == "s1")
        let kept = try #require(try await store.card(old.id))
        #expect(kept.status == .done && kept.piSessionID == "s1")
        #expect(try await store.cueBoard().sessions.isEmpty, "s2 随做完的事收起，s1 归了新任务")
        let taken = try #require(await cue.call("task", ["action": "add", "title": "再补一处", "session": "s1"]))
        #expect(taken.isError && taken.text.contains("正在做「补注册页」"))
    }

    @Test func 不再用的会话_Cue收得掉_在用的不收() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        let recorder = StateRecorder(store: store, hostID: services.hostID)
        for (id, title) in [("s1", "修登录"), ("s2", "随便问问")] {
            try await recorder.update(sessionID: id, state: .settled, title: title, hosted: true, agent: .pi)
        }
        let workspace = Workspace(services: services)
        try await rig.offersPi()
        workspace.startFresh(task)
        let launch = try #require(try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil })
        try await recorder.update(sessionID: "s1", state: .settled, launchToken: launch.launch?.token)
        let executor = DeliveryExecutor(store: store, hostID: services.hostID, onIssue: { Issue.record("\($0)") }) { request, _ in
            if request.mode == .known(.end), let id = request.target.ref { _ = try? await recorder.update(sessionID: id, state: .ended) }
            return .succeeded
        }
        try await executor.start()
        defer { await executor.stop() }
        let cue = CueTools(store: store, wait: 5)
        func ended(_ id: String) async throws -> Bool {
            let end = try #require(try await store.deliveryRequests(toSession: id).last { $0.mode == .known(.end) })
            #expect(try await store.outcome(of: end).status == .known(.succeeded))
            return try await store.sessionItems(sessionIDs: [id])[id]?.state.state == .known(.ended)
        }

        let busy = try #require(await cue.call("task", ["action": "done", "session": "s1"]))
        #expect(busy.isError && busy.text.contains("还在用"))
        #expect(try await store.deliveryRequests(toSession: "s1").isEmpty)

        let done = try #require(await cue.call("task", ["action": "done", "task": task.id.uuidString, "evidence": ["登录不再白屏"]]))
        #expect(done.text.contains("已请 1 个会话结束"))
        #expect(try await ended("s1"))

        let said = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "白屏的根因是什么？"]))
        #expect(!said.isError)
        // Mac 在后台恢复它、答这一句：时刻显式排在完成之后
        let later = try #require(try await store.card(task.id)?.completedAt).addingTimeInterval(1)
        try await recorder.update(sessionID: "s1", state: .thinking, times: SessionTimes(stateSince: later, busySince: later))
        try await recorder.update(sessionID: "s1", state: .settled, times: SessionTimes(stateSince: later.addingTimeInterval(1), busySince: nil))
        #expect(Set(try await store.cueBoard().sessions.map(\.sessionID)) == ["s1", "s2"])

        let again = try #require(await cue.call("task", ["action": "done", "task": task.id.uuidString]))
        #expect(!again.isError && again.text.contains("已请 1 个会话结束"))
        #expect(try await ended("s1"))
        #expect(try await store.cueMessages().count(where: { $0.taskID == task.id }) == 1)

        let closed = try #require(await cue.call("task", ["action": "done", "session": "随便问问"]))
        #expect(!closed.isError && closed.text.contains("已请会话「随便问问」结束"))
        #expect(try await ended("s2"))
        #expect(try await store.cueBoard().sessions.isEmpty)
    }

    @Test func 叶子开新会话又改绑_换下来的会话留在原叶子下() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try services.reconcileLaunch()  // Mac 启动
        try await rig.offersPi()
        let leaf = try await store.createTask("修登录", in: project.id)
        let workspace = Workspace(services: services)
        let recorder = StateRecorder(store: store, hostID: services.hostID)

        var used: Set<String> = []
        for session in ["s1", "s2"] {
            workspace.startFresh(leaf)
            let launch = try await eventually(store, { [used] in
                try $0.deliveryRequests().compactMap(\.launch).first { !used.contains($0.token) }
            }) { $0 != nil }
            let token = try #require(launch).token
            used.insert(token)
            try await recorder.update(sessionID: session, state: .settled, title: "修登录", launchToken: token)
            _ = try await eventually(store, { try $0.card(leaf.id)?.piSessionID }) { $0 == session }
        }
        try await recorder.update(sessionID: "s3", state: .settled, title: "修登录", projectID: project.id)
        try await store.bindSession("s3", to: leaf.id)

        #expect(try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).map(\.id) == [leaf.id])
        #expect(try await store.archived().isEmpty)
        #expect(try await store.card(leaf.id)?.piSessionID == "s3")
        for old in ["s1", "s2"] {
            #expect(try await store.tasks(boundTo: old).map(\.task.id) == [leaf.id])
        }
    }

    func reply(_ text: String, to sessionID: String, in workspace: Workspace) async throws {
        let session = try #require(try await store.sessionItems(sessionIDs: [sessionID])[sessionID]?.state)
        let box = services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(session, mode: .send), from: box) { $0.text }.value
    }

    func enableCue() async throws {
        let host = services.hostID
        try await store.recordMacPresence(host: host) { true }
        try await store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
        }
    }

    func bridge(_ change: SessionChange) async throws {
        try await services.consumeSessionChanges(AsyncStream { continuation in
            continuation.yield(change)
            continuation.finish()
        })
    }
}
#endif

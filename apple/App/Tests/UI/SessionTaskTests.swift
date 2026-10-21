#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

/// 会话是一等对象：不经任务开的会话（终端里的 Pi）不长任务，Cue 照样看得到、管得到它；要为它的结果负责时再给它建任务。
/// 说的话与 Cue 的 say 同一条规则：会话在等能代答的提问时说的话就是答案；说话不改任务的状态。
/// 已完成的事用过、还活着的会话算在做，Cue 在它上面做别的事是另建任务绑上它。
/// Cue 值班时管这些会话：CuePad 答得了的提问等 Cue，不算等你。
struct SessionTaskTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    @Test func 终端里开的会话_不长任务_Cue的信封里看得到_能对它说话_也能为它建任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await enableCue()
        try await services.resetPiState()  // Mac 启动
        var session = CuePi.PiSession(
            id: "s1.100", sessionID: "s1", agent: .pi, sessionFile: URL(filePath: "/tmp/never-\(UUID().uuidString).jsonl"), pid: 100,
            cwd: URL(filePath: "/work/x", directoryHint: .isDirectory), terminal: PiTerminal(),
            state: .settled, stateSince: .now)
        session.name = "修登录"
        try await bridge(.appeared(session))

        let empty = try await TaskBoard.read(from: store)
        #expect(empty.todo.isEmpty && empty.advancing.map(\.id) == ["session/s1"])
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: .now, contextUsed: nil, projects: [], changes: [], board: try await store.cueBoard(), waiting: [],
            wake: .idle))
        #expect(envelope.contains("在做 1 件：\n- 会话「修登录」（s1） · 歇着"))

        let cue = CueTools(store: store, wait: 0)
        let said = try #require(await cue.call("task", ["action": "say", "session": "修登录", "text": "补上登录的测试"]))
        #expect(!said.isError && said.text.contains("会话「修登录」"))
        #expect(try await store.deliveryRequests(toSession: "s1").map(\.content) == ["补上登录的测试"])

        let added = try #require(await cue.call("task", ["action": "add", "title": "修好登录", "session": "s1"]))
        #expect(!added.isError)
        let row = try #require(try await TaskBoard.read(from: store).advancing.first?.item)
        #expect(row.task.title == "修好登录" && row.project?.id == project.id && row.task.piSessionID == "s1")
        #expect(try await store.cueBoard().sessions.isEmpty)
    }

    /// 回复框与 Cue 的 say 同一条规则：会话在等 CuePad 答得了的提问时，说的话就是答案（选项原文或序号），否则照常发出。
    /// 说话不改任务的状态：对已完成的事的会话说的话、作的答送到了，任务仍是完成。状态只由明确的动作改：
    /// Cue 的 edit reopen 同你点掉圆圈（没完成的不让改回），加步骤回到进行中。
    @Test func 对已完成任务的会话说话_任务仍是完成_改回或加步骤才变() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let workspace = Workspace(services: services)
        try await store.bindSession("s1", to: task.id)
        try await workspace.toggle(task.id)
        #expect(try await store.card(task.id)?.status == .done)
        let executor = DeliveryExecutor(store: store, hostID: services.hostID, onIssue: { Issue.record("\($0)") }) { _ in .succeeded }
        try await executor.start()
        defer { Task { await executor.stop() } }

        try await reply("登录后还是白屏", to: "s1", in: workspace)
        let sent = try #require(try await store.deliveryRequests(toSession: "s1").last)
        #expect(sent.mode == .known(.send))
        #expect(try await store.outcome(of: sent).status == .known(.succeeded))
        #expect(try await store.card(task.id)?.status == .done)

        let question = PiQuestion(promptID: "p1", kind: .select, text: "旧数据怎么办？", options: ["覆盖", "跳过"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        try await reply("2", to: "s1", in: workspace)
        #expect(try await store.deliveryRequests(toSession: "s1").last?.answer == PiAnswer(promptID: "p1", value: .option("跳过")))

        let cue = CueTools(store: store, wait: 0)
        let answered = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "覆盖"]))
        #expect(!answered.isError && answered.text.contains("回答"))
        let answer = try #require(try await store.deliveryRequests(toSession: "s1").last)
        #expect(answer.answer == PiAnswer(promptID: "p1", value: .option("覆盖")))
        #expect(try await store.outcome(of: answer).status == .known(.succeeded))
        #expect(try await store.card(task.id)?.status == .done)

        let reopened = try #require(await cue.call("task", ["action": "edit", "task": task.id.uuidString, "reopen": true]))
        #expect(!reopened.isError)
        #expect(try await store.card(task.id)?.status == .inProgress)  // 绑过会话就是开始过
        let again = try #require(await cue.call("task", ["action": "edit", "task": task.id.uuidString, "reopen": true]))
        #expect(again.isError)

        try await workspace.toggle(task.id)
        _ = try await store.createTask("补测试", under: task.id)
        #expect(try await store.card(task.id)?.status == .inProgress)
    }

    /// 已完成的事用过、还活着的会话不归没做完的事：信封"在做"、不带参数的 peek 都有它，它的动静只报一次；peek 末尾列着最近完成的事和它的会话。
    /// Cue 在它上面做别的事：add 带 session 另建任务绑上它，旧任务照旧完成、照旧绑着；会话正被没做完的事用着时不让再绑。
    @Test func 已完成的事的会话还活着_算在做_Cue在它上面另建任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await enableCue()
        let old = try await store.createTask("修登录", in: project.id)
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let workspace = Workspace(services: services)
        try await store.bindSession("s1", to: old.id)
        let mark = try await store.lastWrite()
        try await recorder.update(sessionID: "s1", state: .thinking, turnStartedAt: .now)
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "修登录", lastReply: "修好了", answeredAt: .now)))
        try await recorder.update(sessionID: "s1", state: .settled)
        try await workspace.toggle(old.id)
        #expect(try await store.cueChanges(after: CueMarks(mark)).due.filter { $0.kind == .settled }.map(\.task?.id) == [old.id])

        let board = try await store.cueBoard()
        #expect(board.sessions.map(\.sessionID) == ["s1"])
        let envelope = CueEnvelope.render(CueEnvelope.Input(
            now: .now, contextUsed: nil, projects: [], changes: [], board: board, waiting: [], wake: .idle))
        #expect(envelope.contains("在做 1 件：\n- 会话「修登录」（s1） · 歇着"))
        // 分步做完的事：会话在前一步上，最后一步是手点完成的、没绑会话，列的仍是它用过的会话
        let stepped = try await store.createTask("加语言参数", in: project.id)
        let first = try await store.createTask("加 --lang", under: stepped.id)
        let second = try await store.createTask("写 README", under: stepped.id)
        try await recorder.update(sessionID: "s2", state: .settled, title: "加 --lang")
        try await store.bindSession("s2", to: first.id)
        try await workspace.toggle(first.id)
        try await workspace.toggle(second.id)
        try await workspace.toggle(stepped.id)
        let cue = CueTools(store: store, wait: 0)
        let peek = try #require(await cue.call("task", ["action": "peek"]))
        #expect(peek.text.contains("- 会话「修登录」（s1） · 歇着"))
        #expect(peek.text.contains("最近完成的") && peek.text.contains("- 修登录（\(old.id.shortID)） · 会话「修登录」（s1） · 歇着"))
        #expect(peek.text.contains("- 加语言参数（\(stepped.id.shortID)） · 会话「加 --lang」（s2） · 歇着"))

        let added = try #require(await cue.call("task", ["action": "add", "title": "补注册页", "session": "s1"]))
        #expect(!added.isError)
        let fresh = try #require(try await TaskBoard.read(from: store).advancing.first?.item?.task)
        #expect(fresh.title == "补注册页" && fresh.piSessionID == "s1")
        let kept = try #require(try await store.card(old.id))
        #expect(kept.status == .done && kept.piSessionID == "s1")
        #expect(try await store.cueBoard().sessions.map(\.sessionID) == ["s2"])
        let taken = try #require(await cue.call("task", ["action": "add", "title": "再补一处", "session": "s1"]))
        #expect(taken.isError && taken.text.contains("正在做「补注册页」"))
    }

    /// Cue 收得掉不再用的会话，"在做"里不再有它们：做完的事的会话被 say 恢复、答完空着，再 done 那件事就照做完时的规则结束它（结果只告诉一次）；
    /// 没绑任务的会话（他开的）done 给 session 结束；没做完的事还在用的会话不收，报出原因。
    @Test func 不再用的会话_Cue收得掉_在用的不收() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        for (id, title) in [("s1", "修登录"), ("s2", "随便问问")] {
            try await recorder.update(sessionID: id, state: .settled, title: title, hosted: true, agent: .pi)
        }
        try await store.bindSession("s1", to: task.id)
        let executor = DeliveryExecutor(store: store, hostID: services.hostID, onIssue: { Issue.record("\($0)") }) { request in
            if request.mode == .known(.end), let id = request.target.ref { _ = try? await recorder.update(sessionID: id, state: .ended) }
            return .succeeded
        }
        try await executor.start()
        defer { Task { await executor.stop() } }
        let cue = CueTools(store: store, wait: 5)
        /// 最近那条结束请求执行完（执行器先把会话记成已结束再报成功）后会话是不是已结束。
        func ended(_ id: String) async throws -> Bool {
            let end = try #require(try await store.deliveryRequests(toSession: id).last { $0.mode == .known(.end) })
            #expect(try await store.outcome(of: end).status == .known(.succeeded))
            return try await store.piSessions(sessionIDs: [id])[id]?.state.state == .known(.ended)
        }

        let busy = try #require(await cue.call("task", ["action": "done", "session": "s1"]))
        #expect(busy.isError && busy.text.contains("还在用"))
        #expect(try await store.deliveryRequests(toSession: "s1").isEmpty)

        let done = try #require(await cue.call("task", ["action": "done", "task": task.id.uuidString, "evidence": ["登录不再白屏"]]))
        #expect(done.text.contains("已请 1 个会话结束"))
        #expect(try await ended("s1"))

        let said = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "白屏的根因是什么？"]))
        #expect(!said.isError)
        try await recorder.update(sessionID: "s1", state: .thinking)  // Mac 在后台恢复它、答这一句
        try await recorder.update(sessionID: "s1", state: .settled)
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
        try await services.resetPiState()  // Mac 启动
        try await rig.offersPi()
        let leaf = try await store.createTask("修登录", in: project.id)
        let workspace = Workspace(services: services)
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)

        // 开新会话两次：Mac 开好的会话带着认领标识记下
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
        // 改绑到另一个会话
        try await store.bindSession("s3", to: leaf.id)
        try await recorder.update(sessionID: "s3", state: .settled, title: "修登录")

        #expect(try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).map(\.id) == [leaf.id])
        #expect(try await store.archived().isEmpty)
        #expect(try await store.card(leaf.id)?.piSessionID == "s3")
        for old in ["s1", "s2"] {
            #expect(try await store.tasks(boundTo: old).map(\.task.id) == [leaf.id])
        }
    }

    /// 在会话页的回复框里写下 `text` 发出（与界面的发送按钮同一条路）。
    func reply(_ text: String, to sessionID: String, in workspace: Workspace) async throws {
        let session = try #require(try await store.piSessions(sessionIDs: [sessionID])[sessionID]?.state)
        let box = services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(session, mode: .send), from: box) { $0.text }?.value
    }

    func enableCue() async throws {
        let host = services.hostID
        try await store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
        }
    }

    func bridge(_ change: PiSessionChange) async throws {
        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(change)
            continuation.finish()
        })
    }
}
#endif

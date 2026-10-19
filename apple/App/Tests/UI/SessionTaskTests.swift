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
            cwd: URL(filePath: "/work/x", directoryHint: .isDirectory), terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version,
            state: .settled, stateSince: .now)
        session.name = "修登录"
        try await bridge(.appeared(session))

        #expect(try await TaskBoard.read(from: store).order.isEmpty)
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
        let row = try #require(try await TaskBoard.read(from: store).inProgress.first)
        #expect(row.task.title == "修好登录" && row.project?.id == project.id && row.task.piSessionID == "s1")
        #expect(try await store.cueBoard().sessions.isEmpty)
    }

    /// 回复框与 Cue 的 say 同一条规则：会话在等 CuePad 答得了的提问时，说的话就是答案（选项原文或序号），否则照常发出。
    /// 说话不改任务的状态：对已完成的事的会话说的话、作的答送到了，任务仍是完成。状态只由明确的动作改：
    /// Cue 的 edit reopen 同你点掉圆圈（没完成的不让改回），加步骤回到进行中。
    @Test func 对已完成任务的会话说话_任务仍是完成_改回或加步骤才变() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录", in: nil)
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
        #expect(try await store.outcome(of: sent.id).status == .known(.succeeded))
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
        #expect(try await store.outcome(of: answer.id).status == .known(.succeeded))
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
        try await recorder.update(sessionID: "s1", state: .thinking)
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [], recap: PiRecap(lastPrompt: "修登录", lastReply: "修好了")))
        try await recorder.update(sessionID: "s1", state: .settled)
        try await workspace.toggle(old.id)
        #expect(try await store.cueChanges(after: CueMarks(mark)).filter { $0.kind == .settled }.map(\.task?.id) == [old.id])

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
        let fresh = try #require(try await TaskBoard.read(from: store).inProgress.first?.task)
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
        let task = try await store.createTask("修登录", in: nil)
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
            #expect(try await store.outcome(of: end.id).status == .known(.succeeded))
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

    @Test func 只在会话文件里的历史会话_从头重读也不改写记录() async throws {
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "old.jsonl")
        try """
            {"type":"session","version":3,"id":"old","timestamp":"2026-09-01T08:00:00.000Z","cwd":"/work/x"}
            {"type":"message","id":"u1","parentId":null,"timestamp":"2026-09-01T08:00:01.237Z","message":{"role":"user","content":"整理发布脚本","timestamp":1}}
            {"type":"message","id":"a1","parentId":"u1","timestamp":"2026-09-01T08:00:09.613Z","message":{"role":"assistant","content":[{"type":"text","text":"好了"}],"stopReason":"stop","timestamp":2}}

            """.write(to: file, atomically: true, encoding: .utf8)
        // 没有检查点、从头读：首次回填，或升级作废检查点之后
        func backfill() async {
            await services.consumePiHistory(AsyncStream { continuation in
                continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, transcript: false, files: store.files)))
                continuation.yield(.backfillFinished(sessionFiles: [file]))
                continuation.finish()
            }, agent: .pi)
        }
        await backfill()

        #expect(try await store.piSessions(sessionIDs: ["old"])["old"]?.state.state == .known(.ended))
        let written = try #require(try await store.piSessions(sessionIDs: ["old"])["old"]?.state)
        #expect(written.title == "整理发布脚本" && written.lastReply == "好了")

        try await Task.sleep(for: .milliseconds(5))  // 改写了的话修改时间一定不同
        await backfill()
        #expect(try await store.piSessions(sessionIDs: ["old"])["old"]?.state == written)
    }

    /// 会话里谁说的按来源认（会话页的气泡与 Cue 的 peek 同一条）：Cue 发进去的是"你"，在 CuePad 里发的与终端里打的都是"他"。
    /// 他发起的那一轮还在跑时，Cue 要"马上说"也只排到这一轮做完再发；Cue 自己发起的那一轮里照常马上说。
    @Test func 会话消息按来源标注_他那一轮没完时Cue不插嘴() async throws {
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        let task = try await store.createTask("修登录", in: nil)
        try await store.linkCard(task.id, toSession: "s1")
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let target = SendTarget(kind: .piSession, name: "修登录", ref: "s1")
        let byCue = UUID(), byPad = UUID(), byCueLater = UUID()
        try await store.recordSend("先跑测试", to: target, delivery: byCue, origin: .known(.cue))
        try await store.recordSend("别动登录页样式", to: target, delivery: byPad)
        func said(_ seq: Int64, _ text: String, _ delivery: UUID?) -> PiChatMessage {
            PiChatMessage(sessionID: "s1", entryID: "u\(seq)", seq: seq, role: .user, text: text, at: .now, deliveryID: delivery)
        }
        let reply = PiChatMessage(sessionID: "s1", entryID: "a2", seq: 2, role: .pi, text: "测试全过", at: .now)
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s1", messages: [said(1, "先跑测试", byCue), reply, said(3, "别动登录页样式", byPad), said(4, "顺便看下注册页", nil)],
            recap: PiRecap()))
        try await recorder.update(sessionID: "s1", state: .thinking)  // 终端里那句开的这一轮在跑

        let digest = try await SessionDigest.read(PiSessionState.recordID(sessionID: "s1"), sessionID: "s1", from: store)
        #expect(PiChat.entries(digest.messages, cueSent: digest.cueSent).filter { $0.role == .user }.map(\.fromCue) == [true, false, false])
        let cue = CueTools(store: store)
        let peek = try #require(await cue.call("task", ["action": "peek", "task": task.id.uuidString]))
        #expect(peek.text.contains("你：先跑测试") && peek.text.contains("他：别动登录页样式") && peek.text.contains("他：顺便看下注册页"))

        let waited = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "注册页先别动", "when": "now"]))
        #expect(!waited.isError && waited.text.contains("等它做完再说"))

        // Cue 自己说的那句开的一轮：照常马上说
        try await store.recordSend("再跑一遍", to: target, delivery: byCueLater, origin: .known(.cue))
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [said(5, "再跑一遍", byCueLater)], recap: PiRecap()))
        let steered = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "只跑登录的", "when": "now"]))
        #expect(!steered.isError && steered.text.contains("马上说"))
    }

    /// 这一轮是谁开的只看会话里最近一条你一方或机器的消息：他说的那一轮，变化标"他说的"；FireCode 这类扩展投进来的机器消息开的一轮
    /// 既不算他的也不算 Cue 的——不标"他说的"，Cue 用 now 说话照常马上插进去。
    @Test func 机器消息开的一轮_不标他说的_Cue能马上说() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录", in: nil)
        try await store.linkCard(task.id, toSession: "s1")
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .thinking, title: "修登录")
        let byPad = UUID()
        try await store.recordSend("别动登录页样式", to: SendTarget(kind: .piSession, name: "修登录", ref: "s1"), delivery: byPad)
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [
            PiChatMessage(sessionID: "s1", entryID: "u1", seq: 1, role: .user, text: "别动登录页样式", at: .now, deliveryID: byPad),
            PiChatMessage(sessionID: "s1", entryID: "a1", seq: 2, role: .pi, text: "好", at: .now),
        ], recap: PiRecap(lastPrompt: "别动登录页样式", lastReply: "好")))
        func settledLine(after mark: Int) async throws -> String {
            try await recorder.update(sessionID: "s1", state: .settled)
            let changes = try await store.cueChanges(after: CueMarks(mark)).filter { $0.kind == .settled }
            return CueEnvelope.render(CueEnvelope.Input(
                now: .now, contextUsed: nil, projects: [], changes: changes, board: try await store.cueBoard(),
                waiting: [], wake: .sessionActivity))
        }
        // 他刚在会话里说过话：同时标着他在场
        #expect(try await settledLine(after: try await store.lastWrite()).contains("[歇下 · 他说的 · 他在场：刚在里面说过话] 修登录"))

        let mark = try await store.lastWrite()
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [
            PiChatMessage(sessionID: "s1", entryID: "m3", seq: 3, role: .machine, text: "<firecode_master_event>\n子代理交回：测试全过\n</firecode_master_event>", at: .now),
        ], recap: PiRecap(lastPrompt: "别动登录页样式", lastReply: "测试全过")))
        try await recorder.update(sessionID: "s1", state: .thinking)  // 机器消息开的这一轮在跑
        let said = try #require(await CueTools(store: store, wait: 0).call("task", ["action": "say", "task": task.id.uuidString, "text": "顺便跑一遍 lint", "when": "now"]))
        #expect(!said.isError && said.text.contains("马上说"))
        let line = try await settledLine(after: mark)
        #expect(line.contains("[歇下 · 他在场：刚在里面说过话] 修登录") && !line.contains("他说的"))
    }

    /// Cue 值班时，会话等的回答 CuePad 答得了就归 Cue：显示"等 Cue 回答"、不算进"等你 N"、不给手机推；答不了的照样等你。
    /// Cue 停用后，答得了的那个也回到"等你确认"。
    /// 它运行的那台 Mac 不在线（在线记录过了期限没续：崩溃、断电、断网）也不算值班：答得了的提问回到等你、算进"等你"、置推送标志，
    /// 到期自己变，不用等库里再写什么；那台 Mac 续上在线，又归 Cue。
    @Test(.timeLimit(.minutes(1)))
    func Cue值班时_答得了的提问等Cue_答不了的_那台Mac不在线与停用后等你() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let services: AppServices = app.services, store = services.store
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-b") { true }  // mac-b 醒着：它的在线记录同步到这里
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        let questions = [("s1", PiQuestion(promptID: "p", kind: .confirm, text: "继续？")), ("s2", PiQuestion(promptID: nil, kind: .confirm, text: "在终端里确认"))]
        for (session, question) in questions {
            try await recorder.update(sessionID: session, state: .thinking, title: session)
            try await recorder.update(sessionID: session, state: .waitingForUser, question: question)
        }
        let workspace = Workspace(services: services)
        func shown() async throws -> [String: String] {
            services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
            return Dictionary(uniqueKeysWithValues: services.liveSessions.live.map { ($0.state.sessionID, workspace.shown($0).label) })
        }
        #expect(try await shown() == ["s1": "等 Cue 回答", "s2": "等你确认"])
        #expect(try await CueWaiting.count(in: store) == 1)
        let states = try await store.piSessions(sessionIDs: ["s1", "s2"])
        #expect(states["s1"] != nil && states["s1"]?.state.notify == nil)
        #expect(states["s2"]?.state.notify == .known(.waitingForUser))

        // mac-b 之后再没续期：期限（`MacPresence.lifetime`）一到"等你"自己从 1 变 2
        var counts = store.observe({ try CueWaiting.count(in: $0) }).makeAsyncIterator()
        #expect(try await counts.next() == 1)
        await clock.waitForSleeper()
        clock.advance(.seconds(MacPresence.lifetime))
        #expect(try await counts.next() == 2)
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认"])
        try await recorder.update(sessionID: "s3", state: .thinking, title: "s3")
        try await recorder.update(sessionID: "s3", state: .waitingForUser, question: PiQuestion(promptID: "p3", kind: .confirm, text: "删旧分支？"))
        #expect(try await store.piSessions(sessionIDs: ["s3"])["s3"]?.state.notify == .known(.waitingForUser))

        // mac-b 续上在线：又在值班
        try await store.recordMacPresence(host: "mac-b") { true }
        #expect(try await shown() == ["s1": "等 Cue 回答", "s2": "等你确认", "s3": "等 Cue 回答"])
        #expect(try await CueWaiting.count(in: store) == 1)

        try await store.updateCueProfile { $0.enabledAt = nil }
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认", "s3": "等你确认"])
        #expect(try await CueWaiting.count(in: store) == 3)
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
    private func reply(_ text: String, to sessionID: String, in workspace: Workspace) async throws {
        let session = try #require(try await store.piSessions(sessionIDs: [sessionID])[sessionID]?.state)
        let box = services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: text)
        await workspace.speak(to: .session(session, mode: .send), from: box) { $0.text }?.value
    }

    private func enableCue() async throws {
        let host = services.hostID
        try await store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
        }
    }

    private func bridge(_ change: PiSessionChange) async throws {
        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(change)
            continuation.finish()
        })
    }
}
#endif

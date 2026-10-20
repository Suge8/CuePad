#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

/// 会话里的话归谁、停下归谁接手、提问等谁答。
extension SessionTaskTests {
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
    /// 他发起的那一轮还在跑时，Cue 说话会打断他：不说、报错，等它歇下再说；Cue 自己发起的那一轮里照常打断插话；
    /// 打断不了的会话（终端里的 Claude Code）在跑时也不说。
    @Test func 会话消息按来源标注_他那一轮没完时Cue不插嘴() async throws {
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        let task = try await store.createTask("修登录")
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
        let cue = CueTools(store: store, wait: 0)
        let peek = try #require(await cue.call("task", ["action": "peek", "task": task.id.uuidString]))
        #expect(peek.text.contains("你：先跑测试") && peek.text.contains("他：别动登录页样式") && peek.text.contains("他：顺便看下注册页"))

        let refused = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "注册页先别动"]))
        #expect(refused.isError && refused.text.contains("他发起的一轮"))
        #expect(try await store.deliveryRequests().isEmpty)

        // Cue 自己说的那句开的一轮：照常插话
        try await store.recordSend("再跑一遍", to: target, delivery: byCueLater, origin: .known(.cue))
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [said(5, "再跑一遍", byCueLater)], recap: PiRecap()))
        let interrupted = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "只跑登录的"]))
        #expect(!interrupted.isError && interrupted.text.contains("对「修登录」的会话说"))

        // 终端里的 Claude Code 在跑：CuePad 打断不了它，谁开的这一轮都不说
        let terminal = try await store.createTask("修注册")
        try await store.linkCard(terminal.id, toSession: "s2")
        try await recorder.update(sessionID: "s2", state: .tool, title: "修注册", agent: .claudeCode)
        let blocked = try #require(await cue.call("task", ["action": "say", "task": terminal.id.uuidString, "text": "先停一下"]))
        #expect(blocked.isError && blocked.text.contains("打断不了"))
    }

    /// 会话停下归谁接手看这一轮是谁开的（会话里最近一句你一方的话）与他在不在场（开着它，或 10 分钟内在里面说过话）：
    /// Cue 说的那句开的归 Cue，他刚在里面说过话也照常报给它；他开的，他在场就归他、不报给 Cue，不在场才报，标"他说的"。
    /// FireCode 这类扩展投进来的机器消息（子代理交回）开的轮跟着它之前那句：他的照样归他、在跑时 Cue 不插嘴，Cue 的照样报给 Cue。
    @Test func 停下归谁接手_Cue开的归Cue_他开的他在场时归他_子代理交回跟着开它的那句() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        try await store.linkCard(task.id, toSession: "s1")
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let target = SendTarget(kind: .piSession, name: "修登录", ref: "s1")
        var seq: Int64 = 0
        /// role 一方说了 text（delivery 是那句的发送记录）开一轮，返回开之前的写入序号
        func open(_ role: PiChatRole, _ text: String, at time: Date = .now, delivery: UUID? = nil) async throws -> Int {
            let mark = try await store.lastWrite()
            seq += 2
            try await recorder.update(sessionID: "s1", state: .thinking, turnStartedAt: .now)
            try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [
                PiChatMessage(sessionID: "s1", entryID: "o\(seq)", seq: seq - 1, role: role, text: text, at: time, deliveryID: delivery),
                PiChatMessage(sessionID: "s1", entryID: "a\(seq)", seq: seq, role: .pi, text: "好", at: .now),
            ], recap: PiRecap(lastPrompt: text, lastReply: "好", answeredAt: .now)))
            return mark
        }
        /// 这一轮做完歇下：报给 Cue 的那一行（没报为 nil），与它是不是归他
        func settle(after mark: Int) async throws -> (line: String?, his: Bool) {
            try await recorder.update(sessionID: "s1", state: .settled)
            let changes = try await store.cueChanges(after: CueMarks(mark))
            let envelope = CueEnvelope.render(CueEnvelope.Input(
                now: .now, contextUsed: nil, projects: [], changes: changes.due, board: try await store.cueBoard(), waiting: [], wake: .sessionActivity([])))
            return (envelope.split(separator: "\n").first { $0.hasPrefix("- [歇下") }.map(String.init), changes.held["s1"] != nil)
        }

        // 他 11 分钟前在终端里说的那一轮：他已不在场，报给 Cue，标"他说的"
        var stop = try await settle(after: try await open(.user, "先跑测试", at: .now - 11 * 60))
        #expect(stop.line?.hasPrefix("- [歇下 · 他说的] 修登录") == true && !stop.his)

        // 他刚在 CuePad 里说的那一轮（发送记录不是 Cue 的）：他在场，归他
        let byPad = UUID()
        try await store.recordSend("别动登录页样式", to: target, delivery: byPad)
        stop = try await settle(after: try await open(.user, "别动登录页样式", delivery: byPad))
        #expect(stop.line == nil && stop.his)

        // 他那句派出的子代理交回、机器消息开的一轮：在跑时 Cue 不插嘴；停下时他在场，同样归他
        let returned = "<firecode_master_event>\n子代理交回：测试全过\n</firecode_master_event>"
        var machine = try await open(.machine, returned)
        let said = try #require(await CueTools(store: store, wait: 0).call("task", ["action": "say", "task": task.id.uuidString, "text": "顺便跑一遍 lint"]))
        #expect(said.isError && said.text.contains("他发起的一轮"))
        stop = try await settle(after: machine)
        #expect(stop.line == nil && stop.his)

        // Cue 说的那句开的一轮：他刚在里面说过话也归 Cue，照常报，不标"他说的"
        let byCue = UUID()
        try await store.recordSend("再跑一遍", to: target, delivery: byCue, origin: .known(.cue))
        stop = try await settle(after: try await open(.user, "再跑一遍", delivery: byCue))
        #expect(stop.line?.hasPrefix("- [歇下] 修登录") == true && !stop.his)

        // Cue 那句派出的子代理交回、接着跑完的一轮：他在场也报给 Cue
        machine = try await open(.machine, returned)
        stop = try await settle(after: machine)
        #expect(stop.line?.hasPrefix("- [歇下] 修登录") == true && !stop.his)
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
        #expect(try await store.cueTally().waiting.count == 1)
        let states = try await store.piSessions(sessionIDs: ["s1", "s2"])
        #expect(states["s1"] != nil && states["s1"]?.state.notify == nil)
        #expect(states["s2"]?.state.notify == .known(.waitingForUser))

        // mac-b 之后再没续期：期限（`MacPresence.lifetime`）一到"等你"自己从 1 变 2
        var counts = store.observe({ try $0.cueTally().waiting.count }).makeAsyncIterator()
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
        #expect(try await store.cueTally().waiting.count == 1)

        try await store.updateCueProfile { $0.enabledAt = nil }
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认", "s3": "等你确认"])
        #expect(try await store.cueTally().waiting.count == 3)
    }
}
#endif

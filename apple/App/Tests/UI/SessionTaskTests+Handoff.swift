#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
@testable import CueBridge
import Foundation
import Synchronization
import Testing
@testable import CuePad

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
            await services.consumeHistory(AsyncStream { continuation in
                continuation.yield(.updated(try! History.index(file: file, agent: .pi, from: nil, transcript: false, files: store.files)))
                continuation.yield(.backfillFinished(sessionFiles: [file]))
                continuation.finish()
            }, agent: .pi)
        }
        await backfill()

        #expect(try await store.sessionItems(sessionIDs: ["old"])["old"]?.state.state == .known(.ended))
        let written = try #require(try await store.sessionItems(sessionIDs: ["old"])["old"]?.state)
        #expect(written.title == "整理发布脚本" && written.lastReply == "好了")

        await nextMillisecond()  // 改写了的话修改时间一定不同
        await backfill()
        #expect(try await store.sessionItems(sessionIDs: ["old"])["old"]?.state == written)
    }

    @Test func 会话消息按来源标注_他那一轮没完时Cue不插嘴() async throws {
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        let task = try await store.createTask("修登录")
        try await store.linkCard(task.id, toSession: "s1")
        let recorder = try await rig.runtimeRecorder(on: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let target = SendTarget(kind: .piSession, name: "修登录", ref: "s1")
        let byCue = UUID(), byPad = UUID(), byCueLater = UUID()
        try await store.recordSend("先跑测试", to: target, delivery: byCue, origin: .known(.cue))
        try await store.recordSend("别动登录页样式", to: target, delivery: byPad)
        func said(_ seq: Int64, _ text: String, _ delivery: UUID?) -> ChatMessage {
            ChatMessage(sessionID: "s1", entryID: "u\(seq)", seq: seq, role: .user, text: text, at: .now, deliveryID: delivery)
        }
        let reply = ChatMessage(sessionID: "s1", entryID: "a2", seq: 2, role: .pi, text: "测试全过", at: .now)
        try await store.writeTranscript(SessionTranscript(
            sessionID: "s1", messages: [said(1, "先跑测试", byCue), reply, said(3, "别动登录页样式", byPad), said(4, "顺便看下注册页", nil)],
            recap: Recap()))
        try await recorder.update(sessionID: "s1", state: .thinking)  // 终端里那句开的这一轮在跑

        let digest = try await SessionDigest.read(SessionState.recordID(sessionID: "s1"), sessionID: "s1", from: store)
        #expect(Chat.entries(digest.messages, cueSent: digest.cueSent).filter { $0.role == .user }.map(\.fromCue) == [true, false, false])
        let cue = CueTools(store: store, wait: 0)
        let peek = try #require(await cue.call("task", ["action": "peek", "task": task.id.uuidString]))
        #expect(peek.text.contains("你：先跑测试") && peek.text.contains("他：别动登录页样式") && peek.text.contains("他：顺便看下注册页"))

        let refused = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "注册页先别动"]))
        #expect(refused.isError && refused.text.contains("他发起的一轮"))
        #expect(try await store.deliveryRequests().isEmpty)

        try await store.recordSend("再跑一遍", to: target, delivery: byCueLater, origin: .known(.cue))
        try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [said(5, "再跑一遍", byCueLater)], recap: Recap()))
        let interrupted = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "只跑登录的"]))
        #expect(!interrupted.isError && interrupted.text.contains("对「修登录」的会话说"))
    }

    @Test func 停下归开这一轮的人_Cue开的报给Cue_他开的不报_子代理交回跟着开它的那句() async throws {
        try await enableCue()
        let task = try await store.createTask("修登录")
        try await store.linkCard(task.id, toSession: "s1")
        let recorder = try await rig.runtimeRecorder(on: services.hostID)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录")
        let target = SendTarget(kind: .piSession, name: "修登录", ref: "s1")
        var seq: Int64 = 0
        func open(_ role: ChatRole, _ text: String, delivery: UUID? = nil) async throws -> Int {
            let mark = try await store.lastWrite()
            seq += 2
            try await recorder.update(sessionID: "s1", state: .thinking, turnStartedAt: .now)
            try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [
                ChatMessage(sessionID: "s1", entryID: "o\(seq)", seq: seq - 1, role: role, text: text, at: .now, deliveryID: delivery),
                ChatMessage(sessionID: "s1", entryID: "a\(seq)", seq: seq, role: .pi, text: "好", at: .now),
            ], recap: Recap(lastPrompt: text, lastReply: "好", answeredAt: .now)))
            return mark
        }
        func settle(after mark: Int) async throws -> String? {
            try await recorder.update(sessionID: "s1", state: .settled)
            let envelope = CueEnvelope.render(try await CueEnvelope.read(
                from: store, wake: .sessionActivity([]), changes: try await store.cueChanges(after: CueMarks(mark)), now: .now, host: TestApp.hostID,
                language: nil, retrying: nil, related: []))
            return envelope.split(separator: "\n").first { $0.hasPrefix("- [歇下") }.map(String.init)
        }

        #expect(try await settle(after: try await open(.user, "先跑测试")) == nil)

        let byPad = UUID()
        try await store.recordSend("别动登录页样式", to: target, delivery: byPad)
        #expect(try await settle(after: try await open(.user, "别动登录页样式", delivery: byPad)) == nil)

        let returned = "<firecode_master_event>\n子代理交回：测试全过\n</firecode_master_event>"
        var machine = try await open(.machine, returned)
        let said = try #require(await CueTools(store: store, wait: 0).call("task", ["action": "say", "task": task.id.uuidString, "text": "顺便跑一遍 lint"]))
        #expect(said.isError && said.text.contains("他发起的一轮"))
        #expect(try await settle(after: machine) == nil)

        let byCue = UUID()
        try await store.recordSend("再跑一遍", to: target, delivery: byCue, origin: .known(.cue))
        #expect(try await settle(after: try await open(.user, "再跑一遍", delivery: byCue))?.hasPrefix("- [歇下] 修登录") == true)

        machine = try await open(.machine, returned)
        #expect(try await settle(after: machine)?.hasPrefix("- [歇下] 修登录") == true)
    }

    @Test
    func Cue值班时_答得了的提问等Cue_答不了的_那台Mac不在线与停用后等你() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let services: AppServices = app.services, store = services.store
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-b") { true }  // mac-b 醒着：它的在线记录同步到这里
        let recorder = try await app.runtimeRecorder(on: services.hostID)
        let questions = [("s1", Question(promptID: "p", kind: .confirm, text: "继续？")), ("s2", Question(promptID: nil, kind: .confirm, text: "在终端里确认"))]
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
        let states = try await store.sessionItems(sessionIDs: ["s1", "s2"])
        #expect(states["s1"] != nil && states["s1"]?.state.notify == nil)
        #expect(states["s2"]?.state.notify == .alert(.waitingForUser))

        let counts = Mutex<[Int]>([])
        let watching = Task { for try await count in store.observe({ try $0.cueTally().waiting.count }) { counts.withLock { $0.append(count) } } }
        defer { watching.cancel() }  // 订阅一直开着：到期重读靠它登记的计时器
        try await eventually("等 Cue 的 1 件") { counts.withLock { $0.last } == 1 }
        try await clock.waitForSleeper()
        clock.advance(.seconds(MacPresence.lifetime - 1))
        _ = try await app.runtimeRecorder(on: services.hostID)  // Agent 所在的 Mac 仍续期，只让 Cue 那台过期
        clock.advance(.seconds(1))
        try await eventually("Cue 那台过期、等的变 2 件") { counts.withLock { $0.last } == 2 }
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认"])
        try await recorder.update(sessionID: "s3", state: .thinking, title: "s3")
        try await recorder.update(sessionID: "s3", state: .waitingForUser, question: Question(promptID: "p3", kind: .confirm, text: "删旧分支？"))
        #expect(try await store.sessionItems(sessionIDs: ["s3"])["s3"]?.state.notify == .alert(.waitingForUser))

        try await store.recordMacPresence(host: "mac-b") { true }
        #expect(try await shown() == ["s1": "等 Cue 回答", "s2": "等你确认", "s3": "等 Cue 回答"])
        #expect(try await store.cueTally().waiting.count == 1)

        try await store.updateCueProfile { $0.enabledAt = nil }
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认", "s3": "等你确认"])
        #expect(try await store.cueTally().waiting.count == 3)
    }
}
#endif

#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

/// 活着的会话都属于一个任务叶子：不经任务开的会话（终端里的 Pi），Mac 建同名任务挂上，看板与 Cue 都从任务看到它；
/// 只在会话文件里找到的历史会话不补。Cue 值班时管这些会话：CuePad 答得了的提问等 Cue，不算等你。
struct SessionTaskTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    @Test func 终端里开的会话_看板出现同名任务_Cue看得到_名字跟着会话且太长截断_没说话就退出时一起删() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await services.resetPiState()  // Mac 启动
        var session = CuePi.PiSession(
            id: "s1.100", sessionID: "s1", agent: .pi, sessionFile: URL(filePath: "/tmp/never-\(UUID().uuidString).jsonl"), pid: 100,
            cwd: URL(filePath: "/work/x", directoryHint: .isDirectory), terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version,
            state: .settled, stateSince: .now)
        session.name = "修登录"
        try await bridge(.appeared(session))

        let row = try #require(try await TaskBoard.read(from: store).inProgress.first)
        #expect(row.task.title == "修登录" && row.project?.id == project.id && row.session?.sessionID == "s1")
        let overview = try #require(await CueTools(store: store).call("task", ["action": "peek"]))
        #expect(!overview.isError && overview.text.contains("在做 1 件：\n圆桌：\n- 修登录（\(row.task.id.shortID)） · 歇着"))

        // 终端会话的名字常是第一句话：任务名截到 24 宽（汉字算 2）加"…"
        session.name = "修登录跳转并把回调改走统一网关再补上测试"
        try await bridge(.infoChanged(session))
        #expect(try await store.card(row.task.id)?.title == "修登录跳转并把回调改走…")

        try await bridge(.ended(session, reason: .closed(reason: "quit")))
        #expect(try await store.card(row.task.id) == nil)
    }

    @Test func 只在会话文件里的历史会话_启动时不建任务_从头重读也不改写记录() async throws {
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
                continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, transcript: false, files: store.files)))
                continuation.yield(.backfillFinished(sessionFiles: [file]))
                continuation.finish()
            }, agent: .pi)
        }
        await backfill()
        try await services.resetPiState()  // Mac 启动

        #expect(try await store.piSessions(sessionIDs: ["old"])["old"]?.state.state == .known(.ended))
        #expect(try await store.archived().isEmpty)
        #expect(try await TaskBoard.read(from: store).order.isEmpty)
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
        #expect(PiChat.entries(digest.messages, cueSent: digest.cueSent).filter(\.isUser).map(\.fromCue) == [true, false, false])
        let cue = CueTools(store: store)
        let peek = try #require(await cue.call("task", ["action": "peek", "task": task.id.uuidString]))
        #expect(peek.text.contains("你：先跑测试") && peek.text.contains("他：别动登录页样式") && peek.text.contains("他：顺便看下注册页"))

        let waited = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "注册页先别动", "when": "now"]))
        #expect(!waited.isError && waited.structured["mode"] as? String == DeliveryMode.followUp.rawValue)

        // Cue 自己说的那句开的一轮：照常马上说
        try await store.recordSend("再跑一遍", to: target, delivery: byCueLater, origin: .known(.cue))
        try await store.writePiTranscript(PiTranscript(sessionID: "s1", messages: [said(5, "再跑一遍", byCueLater)], recap: PiRecap()))
        let steered = try #require(await cue.call("task", ["action": "say", "task": task.id.uuidString, "text": "只跑登录的", "when": "now"]))
        #expect(!steered.isError && steered.structured["mode"] as? String == DeliveryMode.steer.rawValue)
    }

    /// Cue 值班时，会话等的回答 CuePad 答得了就归 Cue：显示"等 Cue 回答"、不算进"等你 N"、不给手机推；答不了的照样等你。
    /// Cue 停用后，答得了的那个也回到"等你确认"。
    @Test func Cue值班时_答得了的提问等Cue_答不了的和停用后等你() async throws {
        try await store.updateCueProfile {
            $0.hostID = "mac-b"
            $0.enabledAt = .now
        }
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)
        let questions = [("s1", PiQuestion(promptID: "p", kind: .confirm, text: "继续？")), ("s2", PiQuestion(promptID: nil, kind: .confirm, text: "在终端里确认"))]
        for (session, question) in questions {
            try await recorder.update(sessionID: session, state: .thinking, title: session)
            try await recorder.update(sessionID: session, state: .waitingForUser, question: question)
        }
        let workspace = Workspace(services: services)
        func shown() async throws -> [String: String] {
            services.liveSessions.apply(try await LiveSessions.Page.read(from: store))
            return Dictionary(uniqueKeysWithValues: services.liveSessions.live.map { ($0.state.sessionID, workspace.shown($0).label) })
        }
        #expect(try await shown() == ["s1": "等 Cue 回答", "s2": "等你确认"])
        #expect(try await CueWaiting.count(in: store) == 1)
        let states = try await store.piSessions(sessionIDs: ["s1", "s2"])
        #expect(states["s1"] != nil && states["s1"]?.state.notify == nil)
        #expect(states["s2"]?.state.notify == .known(.waitingForUser))

        try await store.updateCueProfile { $0.enabledAt = nil }
        #expect(try await shown() == ["s1": "等你确认", "s2": "等你确认"])
        #expect(try await CueWaiting.count(in: store) == 2)
    }

    @Test func 叶子开新会话又改绑_换下来的会话留在原叶子下_不长新任务() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await services.resetPiState()  // Mac 启动
        let leaf = try await store.createTask("修登录", in: project.id)
        let workspace = Workspace(services: services)
        let recorder = PiStateRecorder(store: store, hostID: services.hostID)

        // 开新会话两次：Mac 开好的会话带着认领标识记下
        var used: Set<String> = []
        for session in ["s1", "s2"] {
            workspace.startFresh(leaf.id)
            let launch = try await eventually(store, { [used] in
                try $0.deliveryRequests().compactMap(\.launch).first { !used.contains($0.token) }
            }) { $0 != nil }
            let token = try #require(launch).token
            used.insert(token)
            try await recorder.update(sessionID: session, state: .settled, title: "修登录", launchToken: token)
            _ = try await eventually(store, { try $0.card(leaf.id)?.piSessionID }) { $0 == session }
        }
        // 改绑到另一个会话
        try await workspace.bind("s3", to: leaf.id)
        try await recorder.update(sessionID: "s3", state: .settled, title: "修登录")
        try await services.resetPiState()  // 再启动一次：启动时的归位也不给换下来的会话补任务

        #expect(try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).map(\.id) == [leaf.id])
        #expect(try await store.archived().isEmpty)
        #expect(try await store.card(leaf.id)?.piSessionID == "s3")
        for old in ["s1", "s2"] {
            #expect(try await store.tasks(boundTo: old).map(\.task.id) == [leaf.id])
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

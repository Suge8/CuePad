#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
@Suite(RealAgents.taped(.opencode), .serialized, .timeLimit(.minutes(10)))
struct RealOpenCodeTests {
    func session(_ bridge: PiBridge) -> PiSession? { bridge.sessions.first { $0.agent == .opencode } }

    func withOpenCode(_ body: (OpenCodeSandbox, CueStore, PiBridge, OpenCodeRuntime) async throws -> Void) async throws {
        let sandbox = try await OpenCodeSandbox()
        let store = try Fixture().store
        let bridge = PiBridge(socketDirectory: sandbox.paths.pi.socketDirectory)
        let runtime = sandbox.runtime(bridge, store)
        let outcome: Result<Void, any Error>
        do {
            try runtime.start()
            try await body(sandbox, store, bridge, runtime)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
            await sandbox.dump(bridge)
        }
        await runtime.stop()()
        try await sandbox.stop()
        try outcome.get()
    }

    func replies(_ store: CueStore, _ sessionID: String) async throws -> [String] {
        try await store.piMessages(of: sessionID).filter { $0.role == .known(.pi) }.map(\.text)
    }

    @Test func aTerminalSessionIsLiveInCuePadAndTakesMessagesAnswersAndSettings() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            try await sandbox.run(["run", "Reply with exactly the word PONG and nothing else."])

            // 会话一建好就上桥，那时还没开始这一轮、也就还不知道用的模型（状态同样是歇着）：等回答进了资料库——这一轮的事件都已处理——再看歇下
            try await eventually("终端里的会话上了桥、答完歇下") {
                guard let live = session(bridge), live.state == .settled else { return false }
                return try await replies(store, live.sessionID).last?.contains("PONG") == true
            }
            let live = try #require(session(bridge))
            #expect(live.cwd.resolvingSymlinksInPath() == sandbox.work.resolvingSymlinksInPath())
            #expect(live.model?.key == openCodeTestModel && live.context?.window != nil)
            #expect(live.commands.contains { $0.name == "review" } && live.commands.contains { $0.name == "compact" })
            #expect(try await store.piSessions().contains { $0.id == live.sessionID && $0.agent == .opencode })

            let delivery = UUID()
            try await bridge.send(PiMessage(text: "Reply with exactly the word AGAIN.", deliveryID: delivery.uuidString), to: live.id)
            try await eventually("CuePad 发的那句认得出来，回答也到了") {
                let messages = try await store.piMessages(of: live.sessionID)
                return messages.contains { $0.deliveryID == delivery } && messages.last { $0.role == .known(.pi) }?.text.contains("AGAIN") == true
            }

            try await bridge.configure(PiConfig(name: "改过的名字"), in: live.id)
            try await eventually("改名到了") { session(bridge)?.displayName == "改过的名字" }
            let thinker = openCodeOtherModel
            try await bridge.configure(PiConfig(model: thinker, thinking: .high), in: live.id)
            try await eventually("模型与强度换了") { session(bridge)?.model?.key == thinker && session(bridge)?.thinking == .known(.high) }
            let stored = try await sandbox.api("GET", "/api/session/\(live.sessionID)")["data"] as? [String: Any]
            let model = stored?["model"] as? [String: Any]
            #expect(model?["id"] as? String == thinker.id && model?["variant"] as? String == "high" && stored?["title"] as? String == "改过的名字")
            await #expect(throws: PiBridgeError.unknownModel(.opencode)) {
                try await bridge.configure(PiConfig(model: PiModelKey(provider: openCodeTestModel.provider, id: "no-such-model")), in: live.id)
            }
            await #expect(throws: PiBridgeError.rejected("unknown_command")) { try await bridge.command("/no-such-command", in: live.id) }
            try await bridge.configure(PiConfig(model: openCodeTestModel), in: live.id)

            try await sandbox.api("PATCH", "/api/session/\(live.sessionID)", ["permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
            let marker = sandbox.work.appending(path: "approved.txt")
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: touch approved.txt  Then reply DONE."), to: live.id)
            try await eventually("在等你确认这条命令") { session(bridge)?.question?.isAnswerable == true }
            let question = try #require(session(bridge)?.question)
            #expect(session(bridge)?.state == .waitingForUser && question.text.contains("touch approved.txt"))
            #expect(question.text.hasPrefix("允许 OpenCode 使用 shell？"), "四家同一句式：\(question.text)")
            try await bridge.answer(.option(question.options[0]), to: question.promptID!, in: live.id)
            try await eventually("答了之后命令跑了、这一轮做完") {
                FileManager.default.fileExists(atPath: marker.path) && session(bridge)?.state == .settled
            }

            try await bridge.command("/compact", in: live.id)
            try await eventually("压缩上下文留下一行") {
                try await store.piMessages(of: live.sessionID).contains { $0.text == PiNotice.compacted.rawValue }
            }

            await runtime.stop()()
            #expect(session(bridge) == nil)
            try await store.deletePiSessions(of: .opencode, keepingHostedOn: "mac")
            try runtime.start()
            try await eventually("再接入后会话回来、索引写回") {
                let indexed = try await store.piSession(live.sessionID)
                return session(bridge) != nil && indexed != nil
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了，会话下线") { session(bridge) == nil }
        }
    }

    @Test func aMessageWhileBusyStopsTheRoundAndStartsANewOne() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-q", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: sleep 60 . Then reply SLEPT."), to: id)
            try await eventually("在跑命令") { session(bridge)?.state.isWorking == true }
            let delivery = UUID()
            // 不说明作废，真模型会在新的一轮里把被停下的命令再跑一遍（实测 deepseek-flash）
            try await bridge.send(PiMessage(text: "The earlier request is cancelled, do not run it. Now: what is 6+6", deliveryID: delivery.uuidString), to: id)

            try await eventually("这句开的一轮答完") {
                let messages = try await store.piMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.last?.role == .known(.pi)
                    && messages.contains { $0.deliveryID == delivery }
            }
            let messages = try await store.piMessages(of: sessionID)
            #expect(messages.filter { $0.role == .known(.user) }.map(\.text).last?.contains("Now") == true)
            let now = try #require(messages.firstIndex { $0.deliveryID == delivery })
            #expect(messages[..<now].contains { $0.text == PiNotice.stopped.rawValue }, "被停下的那一轮留了一行已停止")
            #expect(!messages[..<now].contains { $0.role == .known(.pi) }, "被停下的那一轮没有回答")
            #expect(messages.map(\.seq) == messages.map(\.seq).sorted())
        }
    }

    @Test func aStoppedRoundLeavesAStoppedLine() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-s", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: sleep 30 . Then reply SLEPT."), to: id)
            // 停在跑工具的那一步（它带着 aborted 的错误结束），不是还没开始的时候
            try await eventually("在跑命令") { session(bridge)?.state == .tool }
            try await bridge.abort(id)
            try await eventually("停下了，对话里留下'已停止'") {
                let messages = try await store.piMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.map { "\($0.role.rawValue):\($0.text)" }.suffix(1) == ["system:已停止"]
            }
        }
    }

    /// 忙时点结束（同 `RealHostedEndTests` 的第一例）：先停下这一轮（服务把它写成被停下的一轮）再下桥，结束报成功；会话还在服务里，接着说照常。
    @Test func endingABusySessionStopsTheRoundFirst() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-e", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: sleep 30 . Then reply SLEPT."), to: id)
            try await eventually("在跑命令") { session(bridge)?.state == .tool }
            try await bridge.end(id)
            #expect(bridge.session(id: id) == nil)
            try await eventually("对话里留下'已停止'") {
                try await store.piMessages(of: sessionID).map { "\($0.role.rawValue):\($0.text)" }.suffix(1) == ["system:已停止"]
            }
        }
    }

    @Test func aRoundEndedByARejectedPermissionSaysDeclined() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-d", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await sandbox.api("PATCH", "/api/session/\(sessionID)", ["permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: touch declined.txt . Then reply DONE."), to: id)
            try await eventually("在等你确认") { session(bridge)?.question?.isAnswerable == true }
            let question = try #require(session(bridge)?.question)
            try await bridge.answer(.confirmed(false), to: try #require(question.promptID), in: id)

            try await eventually("停下了，对话里写'已拒绝'") {
                let messages = try await store.piMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.map { "\($0.role.rawValue):\($0.text)" }.suffix(1) == ["system:已拒绝"]
            }
            #expect(!FileManager.default.fileExists(atPath: sandbox.work.appending(path: "declined.txt").path))
        }
    }
}
#endif

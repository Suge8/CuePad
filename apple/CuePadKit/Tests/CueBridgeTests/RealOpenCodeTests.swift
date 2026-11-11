#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

@MainActor
@Suite(RealAgents.needs(.opencode), RealAgents.tiered, .serialized, .timeLimit(.minutes(10)))
struct RealOpenCodeTests {
    func session(_ bridge: Bridge) -> Session? { bridge.sessions.first { $0.agent == .opencode } }

    func withOpenCode(_ body: (OpenCodeSandbox, CueStore, Bridge, OpenCodeRuntime) async throws -> Void) async throws {
        let sandbox = try await OpenCodeSandbox()
        let store = try Fixture().store
        let bridge = Bridge(socketDirectory: sandbox.paths.pi.socketDirectory)
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
        try await store.chatMessages(of: sessionID).filter { $0.role == .known(.pi) }.map(\.text)
    }

    /// 发送：终端里 `opencode run` 的会话上了桥、答完歇下，CuePad 再发一句、改名、就地换模型与强度、压缩上下文，接入停了再开会话回来，服务停了会话下线。
    @Test(.tags(.smoke)) func aTerminalSessionIsLiveInCuePadAndTakesMessagesAnswersAndSettings() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            // 2.2.6 的 `run` 没有后台服务时自己带一个私有的、跑完就走：终端用户的服务是先开着的
            try await sandbox.run(["service", "start"])
            try await sandbox.run(["run", "Reply with exactly the word PONG and nothing else."])

            // 会话一建好就上桥，那时还没开始这一轮、也就还不知道用的模型（状态同样是歇着）。回答进资料库不说明这一轮的事件已处理：
            // 连上服务时的快照随即回填对话，直接从服务读，可以早于事件流里的这一轮。模型只有这一轮告诉 CuePad（事件，或快照里已有的回答）
            try await eventually("终端里的会话上了桥、答完歇下") {
                guard let live = session(bridge), live.state == .settled, live.model != nil else { return false }
                return try await replies(store, live.sessionID).last?.contains("PONG") == true
            }
            let live = try #require(session(bridge))
            let service = commandLine(of: try #require(sandbox.service).pid)
            #expect(service.contains("/\(OpenCodeSandbox.pinned.name)/\(OpenCodeSandbox.pinned.version)/"), "起的不是钉住的 OpenCode：\(service)")
            #expect(sandbox.model.requests.contains { $0.api == .chat && $0.model == "echo" && $0.prompt.contains("PONG") && !$0.tools.isEmpty }, "假模型没收到终端里的那句")
            #expect(live.cwd.resolvingSymlinksInPath() == sandbox.work.resolvingSymlinksInPath())
            #expect(live.model?.key == openCodeTestModel && live.context?.window != nil)
            #expect(live.commands.contains { $0.name == "review" } && live.commands.contains { $0.name == "compact" })
            #expect(try await store.indexedSessions().contains { $0.id == live.sessionID && $0.agent == .opencode })

            let delivery = UUID()
            try await bridge.send(SessionMessage(text: "Reply with exactly the word AGAIN.", deliveryID: delivery.uuidString), to: live.id)
            try await eventually("CuePad 发的那句认得出来，回答也到了") {
                let messages = try await store.chatMessages(of: live.sessionID)
                return messages.contains { $0.deliveryID == delivery } && messages.last { $0.role == .known(.pi) }?.text.contains("AGAIN") == true
            }
            #expect(sandbox.model.requests.contains { $0.prompt.contains("AGAIN") && $0.said.contains { $0.contains("PONG") } }, "第二句请求里该带着前一句")

            try await bridge.configure(SessionConfig(name: "改过的名字"), in: live.id)
            try await eventually("改名到了") { session(bridge)?.displayName == "改过的名字" }
            let thinker = openCodeOtherModel
            try await bridge.configure(SessionConfig(model: thinker, thinking: .high), in: live.id)
            try await eventually("模型与强度换了") { session(bridge)?.model?.key == thinker && session(bridge)?.thinking == .known(.high) }
            let stored = try await sandbox.api("GET", "/api/session/\(live.sessionID)")["data"] as? [String: Any]
            let model = stored?["model"] as? [String: Any]
            #expect(model?["id"] as? String == thinker.id && model?["variant"] as? String == "high" && stored?["title"] as? String == "改过的名字")
            await #expect(throws: BridgeError.unknownModel(.opencode)) {
                try await bridge.configure(SessionConfig(model: ModelKey(provider: openCodeTestModel.provider, id: "no-such-model")), in: live.id)
            }
            await #expect(throws: BridgeError.rejected("unknown_command")) { try await bridge.command("/no-such-command", in: live.id) }
            try await bridge.configure(SessionConfig(model: openCodeTestModel), in: live.id)

            try await bridge.command("/compact", in: live.id)
            try await eventually("压缩上下文留下一行") {
                try await store.chatMessages(of: live.sessionID).contains { $0.text == ChatNotice.compacted.rawValue }
            }

            await runtime.stop()()
            #expect(session(bridge) == nil)
            try await store.deleteSessions(of: .opencode, keepingHostedOn: "mac")
            try runtime.start()
            try await eventually("再接入后会话回来、索引写回") {
                let indexed = try await store.indexedSession(live.sessionID)
                return session(bridge) != nil && indexed != nil
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了，会话下线") { session(bridge) == nil }
        }
    }

    /// 权限：要确认的命令，允许了就跑、拒绝了不跑，各留下该留的一行。
    @Test(arguments: [true, false]) func aCommandThatNeedsPermissionRunsWhenAllowedAndNotWhenDeclined(allow: Bool) async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let file = allow ? "approved.txt" : "declined.txt"
            sandbox.model.on("Run the permission command", .call("shell", ["command": "touch \(file)", "description": "Run the requested command"]), .say("DONE"))
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-p", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await sandbox.api("PATCH", "/api/session/\(sessionID)", ["permissions": [["action": "shell", "resource": "*", "effect": "ask"]]])
            try await bridge.send(SessionMessage(text: "Run the permission command"), to: id)
            try await eventually("在等你确认这条命令") { session(bridge)?.question?.isAnswerable == true }
            let question = try #require(session(bridge)?.question)
            #expect(session(bridge)?.state == .waitingForUser && question.text.contains("touch \(file)"))
            #expect(question.text.hasPrefix("允许 OpenCode 使用 shell？"), "四家同一句式：\(question.text)")
            let asked = sandbox.model.requests.count
            try await bridge.answer(allow ? .option(question.options[0]) : .confirmed(false), to: try #require(question.promptID), in: id)

            try await eventually("答了之后这一轮做完") {
                let messages = try await store.chatMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.last.map { allow ? $0.role == .known(.pi) && $0.text.contains("DONE") : $0.text == "已拒绝" } == true
            }
            #expect(FileManager.default.fileExists(atPath: sandbox.work.appending(path: file).path) == allow)
            // 允许了模型拿到命令的结果接着说；拒绝了这一轮到此为止，不再问模型
            #expect(allow ? sandbox.model.requests.count > asked : sandbox.model.requests.count == asked)
        }
    }

    /// 停止：跑着命令时停下，对话里留下“已停止”，再说一句照常回答。
    @Test func aStoppedRoundLeavesAStoppedLineAndTheNextMessageIsAnswered() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            sandbox.model.on("Run the slow command", .call("shell", ["command": "sleep 30", "description": "Run the requested command"]), .say("SLEPT"))
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-s", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Run the slow command"), to: id)
            // 停在跑工具的那一步（它带着 aborted 的错误结束），不是还没开始的时候
            try await eventually("在跑命令") { session(bridge)?.state == .tool }
            try await bridge.abort(id)
            try await eventually("停下了，对话里留下'已停止'") {
                let messages = try await store.chatMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.map { "\($0.role.rawValue):\($0.text)" }.suffix(1) == ["system:已停止"]
            }

            try await bridge.send(SessionMessage(text: "Reply with exactly the word NEXT."), to: id)
            try await eventually("停下之后说的那句得到回答") { try await replies(store, sessionID).last?.contains("NEXT") == true && session(bridge)?.state == .settled }
        }
    }

    /// 停止的另一条路：这一轮还在跑时又说一句，停下在跑的、开新的一轮回答新的这句。
    @Test func aMessageWhileBusyStopsTheRoundAndStartsANewOne() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            sandbox.model.on("Run the slow command", .call("shell", ["command": "sleep 60", "description": "Run the requested command"]), .say("SLEPT"))
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-q", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Run the slow command"), to: id)
            try await eventually("在跑命令") { session(bridge)?.state.isWorking == true }
            let delivery = UUID()
            try await bridge.send(SessionMessage(text: "Now: what is 6+6", deliveryID: delivery.uuidString), to: id)

            try await eventually("这句开的一轮答完") {
                let messages = try await store.chatMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.last?.role == .known(.pi)
                    && messages.contains { $0.deliveryID == delivery }
            }
            let messages = try await store.chatMessages(of: sessionID)
            #expect(messages.filter { $0.role == .known(.user) }.map(\.text).last?.contains("Now") == true)
            let now = try #require(messages.firstIndex { $0.deliveryID == delivery })
            #expect(messages[..<now].contains { $0.text == ChatNotice.stopped.rawValue }, "被停下的那一轮留了一行已停止")
            #expect(!messages[..<now].contains { $0.role == .known(.pi) }, "被停下的那一轮没有回答")
            #expect(messages.map(\.seq) == messages.map(\.seq).sorted())
        }
    }

    /// 起来马上点结束、说出第一句马上点停止或结束（同 `RealHostedEndTests` 的那一例，#81）：都不等满 `AgentTimeouts.stop`；
    /// 结束的会话还在服务里（进程是服务的），只看它下桥。
    @Test(arguments: ["end on open", "stop on first message", "end on first message"])
    func stoppingOrEndingRightAwayDoesNotWaitOutTheStopLimit(_ moment: String) async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            sandbox.model.on("Run the slow command", .call("shell", ["command": "sleep 30", "description": "Run the requested command"]), .say("SLEPT"))
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-now", name: nil, model: nil, thinking: nil)
            if moment != "end on open" { try await bridge.send(SessionMessage(text: "Run the slow command"), to: id) }
            let began = ContinuousClock.now
            if moment == "stop on first message" {
                try await bridge.abort(id)
                try await eventually("停下了") { session(bridge)?.state == .settled }
            } else {
                try await bridge.end(id)
                #expect(bridge.session(id: id) == nil)
            }
            let took = began.duration(to: .now)
            #expect(took < .seconds(10), "用了 \(took)")
        }
    }

    /// 忙时点结束（同 `RealHostedEndTests` 的第一例）：先停下这一轮（服务把它写成被停下的一轮）再下桥，结束报成功。
    @Test func endingABusySessionStopsTheRoundFirst() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            sandbox.model.on("Run the slow command", .call("shell", ["command": "sleep 30", "description": "Run the requested command"]), .say("SLEPT"))
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-e", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Run the slow command"), to: id)
            try await eventually("在跑命令") { session(bridge)?.state == .tool }
            try await bridge.end(id)
            #expect(bridge.session(id: id) == nil)
            try await eventually("对话里留下'已停止'") {
                try await store.chatMessages(of: sessionID).map { "\($0.role.rawValue):\($0.text)" }.suffix(1) == ["system:已停止"]
            }
        }
    }
}
#endif

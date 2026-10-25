#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 本机装的 OpenCode（`brew install opencode`）
let realOpenCodeURL = ExecutableLocator.standard.candidates("opencode").first
/// 测试用的免费模型：缺省 big-pickle，限流时用 `CUEPAD_OPENCODE_MODEL` 换成别的免费模型（`opencode` 提供方下的 id）
let openCodeTestModel = PiModelKey(provider: "opencode", id: ProcessInfo.processInfo.environment["CUEPAD_OPENCODE_MODEL"] ?? "big-pickle")

/// 端到端：真 OpenCode 的后台服务、真模型（免费的 big-pickle，要联网）。CuePad 看得到它的会话、在 CuePad 里跟它说话与作答，
/// 也能在服务没开时自己把它拉起来开新会话、接着已结束的会话。
@MainActor
@Suite(RealAgents.live(.opencode, "录不出录像带：要 OpenCode v2，它的免费模型拒绝自行构建的 v2，见 RealAgents"), .serialized, .timeLimit(.minutes(10)))
struct RealOpenCodeTests {
    func session(_ bridge: PiBridge) -> PiSession? { bridge.sessions.first { $0.agent == .opencode } }

    /// 一台隔离的 OpenCode 加一个空资料库与桥；不论成败，最后停掉接入、按 pid 停掉服务、删掉临时目录。
    func withOpenCode(_ body: (OpenCodeSandbox, CueStore, PiBridge, OpenCodeRuntime) async throws -> Void) async throws {
        let sandbox = try await OpenCodeSandbox()
        let store = try Fixture().store
        let bridge = PiBridge(socketDirectory: sandbox.paths.pi.socketDirectory)
        let runtime = OpenCodeRuntime(bridge: bridge, paths: sandbox.paths, store: store, hostID: "mac", opencode: { await ExecutableLocator.system.candidates("opencode").first })
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

    /// 终端里（`opencode run`，连着后台服务）说过话的会话出现在 CuePad：实时状态、对话进资料库；CuePad 接着跟它说、改名、换模型与强度、
    /// 回答它要你确认的命令；服务停了会话就下线。
    @Test func aTerminalSessionIsLiveInCuePadAndTakesMessagesAnswersAndSettings() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            try await sandbox.run(["run", "Reply with exactly the word PONG and nothing else."])

            try await eventually("终端里的会话上了桥、歇下") { session(bridge)?.state == .settled }
            let live = try #require(session(bridge))
            #expect(live.cwd.resolvingSymlinksInPath() == sandbox.work.resolvingSymlinksInPath())
            #expect(live.model?.key == openCodeTestModel && live.context?.window != nil)
            #expect(live.commands.contains { $0.name == "review" } && live.commands.contains { $0.name == "compact" })
            try await eventually("对话进了资料库") {
                try await replies(store, live.sessionID).last?.contains("PONG") == true
            }
            #expect(try await store.piSessions().contains { $0.id == live.sessionID && $0.agent == .opencode })

            let delivery = UUID()
            try await bridge.send(PiMessage(text: "Reply with exactly the word AGAIN.", deliveryID: delivery.uuidString), to: live.id)
            try await eventually("CuePad 发的那句认得出来，回答也到了") {
                let messages = try await store.piMessages(of: live.sessionID)
                return messages.contains { $0.deliveryID == delivery } && messages.last { $0.role == .known(.pi) }?.text.contains("AGAIN") == true
            }

            try await bridge.configure(name: "改过的名字", in: live.id)
            try await eventually("改名到了") { session(bridge)?.displayName == "改过的名字" }
            let thinker = PiModelKey(provider: "opencode", id: "cat-jam-free")
            try await bridge.configure(model: thinker, thinking: .high, in: live.id)
            try await eventually("模型与强度换了") { session(bridge)?.model?.key == thinker && session(bridge)?.thinking == .known(.high) }
            let stored = try await sandbox.api("GET", "/api/session/\(live.sessionID)")["data"] as? [String: Any]
            let model = stored?["model"] as? [String: Any]
            #expect(model?["id"] as? String == thinker.id && model?["variant"] as? String == "high" && stored?["title"] as? String == "改过的名字")
            await #expect(throws: PiBridgeError.unknownModel(.opencode)) {
                try await bridge.configure(model: PiModelKey(provider: "opencode", id: "no-such-model"), in: live.id)
            }
            await #expect(throws: PiBridgeError.rejected("unknown_command")) { try await bridge.command("/no-such-command", in: live.id) }
            try await bridge.configure(model: openCodeTestModel, in: live.id)

            // 用户给这个会话定了规矩：跑命令要先问
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

            // 断开接入（App 停掉接入、删掉索引）再接入：会话先下线，再接入后重新上桥、索引从头写回
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

    /// 忙的时候说一句：先停下在跑的这一轮（对话里留一行"已停止"），这句开新一轮并得到回答，认得出是这次投送。
    @Test func aMessageWhileBusyStopsTheRoundAndStartsANewOne() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-q", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(PiMessage(text: "Use the shell tool to run exactly: sleep 60 . Then reply SLEPT."), to: id)
            try await eventually("在跑命令") { session(bridge)?.state.isWorking == true }
            let delivery = UUID()
            try await bridge.send(PiMessage(text: "Now: what is 6+6", deliveryID: delivery.uuidString), to: id)

            try await eventually("这句开的一轮答完") {
                let messages = try await store.piMessages(of: sessionID)
                return session(bridge)?.state == .settled && messages.last?.role == .known(.pi)
                    && messages.contains { $0.deliveryID == delivery }
            }
            let messages = try await store.piMessages(of: sessionID)
            #expect(messages.filter { $0.role == .known(.user) }.map(\.text).last?.contains("Now") == true)
            let now = try #require(messages.firstIndex { $0.deliveryID == delivery })
            #expect(messages[..<now].contains { $0.text == PiNotice.stopped.rawValue }, "被停下的那一轮留了一行已停止")
            #expect(!messages.contains { $0.role == .known(.pi) && $0.text.contains("SLEPT") })
            #expect(messages.map(\.seq) == messages.map(\.seq).sorted())
        }
    }

    /// 在 CuePad 里停下跑着的一轮：没有回答，对话里留一行"已停止"（四家同一规则）。
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

    /// 在 CuePad 里拒绝它要跑的命令：OpenCode 随之停下这一轮，对话里写"已拒绝"，不写"已停止"（读起来不像你按了停止）。
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

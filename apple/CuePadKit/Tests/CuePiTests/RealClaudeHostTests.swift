#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 托管进程自己也跑装好的钩子，桥上不多出一个会话。托管的会话让给终端里打开的那个在 `RealClaudeTerminalTests`。
@MainActor
@Suite(RealAgents.taped(.claudeCode))
struct RealClaudeHostTests {
    /// 只看提交那一刻的钩子（`UserPromptSubmit` 在调模型之前），不等模型回答。
    @Test func aWrappedClaudeIsNotSeenTwice() async throws {
        try await ClaudeTestbed.run(wrapper: ClaudeTestbed.passThrough) { testbed in
            try testbed.startConnected()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t-wrapped", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(testbed.bridge.session(id: id)?.sessionID)

            try await testbed.bridge.send(PiMessage(text: "Reply with the single word WRAPPED."), to: id)
            try await eventually("这一轮开始又结束") {
                log.states.contains { $0.isWorking } && testbed.bridge.session(id: id)?.state.isWorking == false
            }
            #expect(log.changes.allSatisfy { if case .appeared(let s) = $0 { s.sessionID != sessionID || s.id == id } else { true } })
        }
    }

    /// 真进程起来、假模型收到了这句话与这张图，是同一条证据：回答是假模型照请求回的 ECHO。
    @Test func aNewHostedSessionTakesAMessageWithAnImage() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)
            let session = try #require(testbed.bridge.session(id: id))
            #expect(session.hosted && session.launchToken == "token-1" && session.agent == .claudeCode)
            #expect(session.availableModels.contains { $0.key.id == claudeTestModel })
            #expect(session.commands.contains { $0.name == "compact" })

            let delivery = UUID().uuidString
            let image = PiImage(mimeType: "image/png", data: redPNG)
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "不用工具，直接看图：它是红色还是蓝色？只答颜色词", images: [image], deliveryID: delivery), to: id)
            try await testbed.waitForTurn(id, since: start)
            try await testbed.waitForDraftLanded(id)

            let transcript = try testbed.transcript(session.sessionFile)
            let said = try #require(transcript.messages.first { $0.role == .known(.user) })
            #expect(said.deliveryID == UUID(uuidString: delivery))
            #expect(said.text.hasPrefix("不用工具，直接看图：它是红色还是蓝色？只答颜色词\n![](cuepad://file/"))
            #expect(transcript.recap.lastReply?.contains("IMAGES[image/png:") == true, "\(String(describing: transcript.recap.lastReply))")
            let request = try #require(testbed.model.requests.last { $0.prompt.contains("看图") })
            #expect(request.api == .messages && request.images.count == 1 && request.model.hasPrefix("claude-haiku"), "\(request.images) \(request.model)")
            #expect(testbed.bridge.sessions.filter { $0.sessionID == session.sessionID }.count == 1)
        }
    }

    /// 允许与拒绝都从桥上答：模型下一次请求带回的工具结果和磁盘上的文件两边对得上。
    @Test(arguments: [true, false]) func cuePadAnswersAPermission(allow: Bool) async throws {
        try await ClaudeTestbed.run(settings: #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let touched = testbed.work.appending(path: "hosted.txt")
            testbed.on("TOUCH") { $0.step == 0 ? .call("Bash", ["command": "touch \(touched.path)", "description": "touch"]) : .say("DONE") }

            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "TOUCH it"), to: id)
            let permission = try await testbed.waitForQuestion(id)
            #expect(permission.kind == .known(.confirm) && permission.text.hasPrefix("允许 Claude Code 使用 Bash？"), "\(permission.text)")
            #expect(!FileManager.default.fileExists(atPath: touched.path), "没答之前不跑")
            try await testbed.bridge.answer(.confirmed(allow), to: try #require(permission.promptID), in: id)
            try await testbed.waitForTurn(id, since: asked)
            try await testbed.waitForDraftLanded(id)

            #expect(FileManager.default.fileExists(atPath: touched.path) == allow)
            let result = try #require(testbed.model.requests.last { $0.prompt.contains("TOUCH") && $0.step == 1 }?.results.last)
            #expect(result.contains("拒绝了") == !allow, "工具结果：\(result)")
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply == "DONE")
        }
    }

    @Test func anIdleHostedSessionExits() async throws {
        try await ClaudeTestbed.run(idleLimit: .seconds(2)) { testbed in
            try testbed.startConnected()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)

            try await eventually("空闲退出") { log.ended.map(\.0.id) == [id] }
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])
        }
    }
}
#endif

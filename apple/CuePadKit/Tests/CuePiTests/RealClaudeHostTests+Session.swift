#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeHostTests {
    @Test func cuePadChangesModelEffortAndNameOfAHostedSession() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let file = try #require(testbed.bridge.session(id: id)?.sessionFile)
            testbed.on("只回复 OK", .say("OK"))
            testbed.model.on({ $0.model == "no-such-model" }) { _ in .fail("model: no-such-model", status: 404) }  // Claude Code 换模型前问一次服务端
            let first = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: first)
            try await testbed.waitForDraftLanded(id)
            #expect(testbed.bridge.session(id: id)?.model?.key.id == claudeTestModel, "\(String(describing: testbed.bridge.session(id: id)?.model))")
            #expect(testbed.model.requests.last { $0.prompt.contains("只回复 OK") }?.model.contains(claudeTestModel) == true)
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)

            try await testbed.bridge.configure(PiConfig(model: other, thinking: .low, name: "托管改名"), in: id)
            await #expect(throws: PiBridgeError.unknownModel(.claudeCode)) {
                try await testbed.bridge.configure(PiConfig(model: PiModelKey(provider: ClaudeCode.provider, id: "no-such-model")), in: id)
            }
            try await testbed.bridge.command("/rename 命令改名", in: id)
            try await eventually("斜杠命令改了名、歇下") {
                testbed.bridge.session(id: id)?.displayName == "命令改名" && testbed.bridge.session(id: id)?.state == .settled
            }
            await #expect(throws: PiBridgeError.rejected("unknown_command")) { try await testbed.bridge.command("/no-such-command", in: id) }

            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            try await testbed.waitForDraftLanded(id)
            let answered = try #require(lastAnswer(in: file))
            #expect(answered.model?.contains(claudeOtherModel) == true, "\(String(describing: answered.model))")
            #expect(answered.effort == "low")
            #expect(try testbed.transcript(file).history.name == "命令改名")
            // 每轮 Claude Code 报的是别名解析后的 id：界面上仍是选的那一项（名字、强度档都在），不回成原始 id
            let model = try #require(testbed.bridge.session(id: id)?.model)
            #expect(model.key == other && model.name != claudeOtherModel && !model.thinkingLevels.isEmpty, "\(model)")
        }
    }

    private func lastAnswer(in file: URL) -> (model: String?, effort: String?)? {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.reversed().lazy.compactMap { JSONValue.parse(Data($0.utf8)) }.first { $0["type"]?.string == "assistant" }
            .map { ($0["message"]?["model"]?.string, $0["effort"]?.string) }
    }

    /// 结束前停下的那一轮，Claude Code 接着时补写的助手消息（"No response requested."）不算它的回答。
    /// 暗号只在历史里：答得出就是重新起的进程把整段对话又交给了模型。
    /// 结束后马上接着：外壳关掉输出后再过一秒才退出，拉开"流断了、进程还没收"的那一段（机器忙时它自己就有这么长）。
    @Test func anEndedHostedSessionIsResumedWithItsHistory() async throws {
        try await ClaudeTestbed.run(wrapper: #""$REAL" "$@"; status=$?; exec >&- 2>&- <&-; sleep 1; exit $status"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let first = try #require(testbed.bridge.session(id: id))
            let gate = testbed.model.gate()
            testbed.on("茶叶史", .held(gate, then: .say("LATE")))
            testbed.on("记住暗号", .say("OK"))
            testbed.on("暗号是什么") { request in
                .say(request.said.lazy.compactMap { $0.firstMatch(of: /暗号 (\w+)/)?.1 }.first.map(String.init) ?? "UNKNOWN")
            }

            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "记住暗号 BANANA42，只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)
            try await testbed.bridge.configure(PiConfig(model: other), in: id)
            let writing = Task { try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id) }
            try await gate.reached()
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }
            try await writing.value
            try await testbed.record(id)
            let log = ChangeLog(testbed.bridge)

            try await testbed.bridge.end(id)
            #expect(testbed.bridge.session(id: id) == nil)
            try await eventually("变化记录里有这次结束") { !log.ended.isEmpty }
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])

            try await testbed.index(first.sessionFile)
            let indexed = IndexedSession(
                id: first.sessionID, path: first.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
            let resumed = try await testbed.runtime.resume(indexed)
            #expect(testbed.bridge.session(id: resumed)?.sessionID == first.sessionID)
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "刚才的暗号是什么？只回复暗号"), to: resumed)
            try await testbed.waitForTurn(resumed, since: asked)
            try await testbed.waitForDraftLanded(resumed)
            #expect(testbed.bridge.session(id: resumed)?.model?.key == other, "\(String(describing: testbed.bridge.session(id: resumed)?.model))")
            #expect(testbed.bridge.session(id: resumed)?.firstMessage == "记住暗号 BANANA42，只回复 OK")
            let transcript = try testbed.transcript(first.sessionFile)
            #expect(transcript.recap.lastReply?.contains("BANANA42") == true)
            #expect(testbed.model.requests.last { $0.prompt.contains("暗号是什么") }?.model.contains(claudeOtherModel) == true)
            let replies = transcript.messages.filter { $0.role == .known(.pi) }.map(\.text)
            #expect(!replies.contains("No response requested."), "\(replies)")
        }
    }
}
#endif

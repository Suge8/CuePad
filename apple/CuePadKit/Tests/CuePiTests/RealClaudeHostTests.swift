#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 托管进程自己也跑装好的钩子，桥上不多出一个会话。托管的会话让给终端里打开的那个在 `RealClaudeTerminalTests`。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.serialWhenRecording(.claudeCode), RealAgents.timeLimit(.minutes(8)))
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
            #expect(transcript.recap.lastReply?.contains("红") == true, "\(String(describing: transcript.recap.lastReply))")
            #expect(testbed.bridge.sessions.filter { $0.sessionID == session.sessionID }.count == 1)
        }
    }

    @Test func cuePadAnswersAPermissionAndStopsARunningTurn() async throws {
        try await ClaudeTestbed.run(settings: #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            try "hello cuepad\n".write(to: testbed.work.appending(path: "seed.txt"), atomically: true, encoding: .utf8)
            let edited = testbed.work.appending(path: "edited.txt")

            let routine = Date()
            try await testbed.bridge.send(
                PiMessage(text: "用 Bash 工具依次执行 ls、cat seed.txt、rg hello（各一条命令），再用 Write 工具写 \(edited.path)，内容是 EDITED，然后只回复 DONE"), to: id)
            try await testbed.waitForTurn(id, since: routine)
            #expect(FileManager.default.fileExists(atPath: edited.path))
            #expect(!testbed.log.states.contains(.waitingForUser), "\(testbed.log.details)")

            let touched = testbed.work.appending(path: "hosted.txt")
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "用 Bash 工具执行 touch \(touched.path) ，然后只回复 DONE"), to: id)
            let permission = try await testbed.waitForQuestion(id)
            #expect(permission.kind == .known(.confirm))
            try await testbed.bridge.answer(.confirmed(true), to: try #require(permission.promptID), in: id)
            try await testbed.waitForTurn(id, since: asked)
            try await testbed.waitForDraftLanded(id)
            #expect(FileManager.default.fileExists(atPath: touched.path))

            try await testbed.bridge.send(PiMessage(text: "用 Bash 工具在前台执行 python3 -c 'import time; time.sleep(120)'（不要放到后台），然后只回复 SLEPT"), to: id)
            // 跑命令也要确认（模型不同，问不问不一定）：问了就允许。不用 sleep：Claude Code 会把它挪到后台
            try await eventually("在跑命令") {
                if let asked = testbed.bridge.session(id: id)?.question?.promptID { try? await testbed.bridge.answer(.confirmed(true), to: asked, in: id) }
                return testbed.bridge.session(id: id)?.state == .tool
            }
            try await testbed.bridge.abort(id)
            try await eventually("停下") { testbed.bridge.session(id: id)?.state == .settled }

            let used = try #require(testbed.bridge.session(id: id)?.context?.tokens)
            // 送达等模型开始回话；这一轮在那之前就被停下：开始了就是收下了
            let writing = Task { try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id) }
            try await eventually("开始这一轮") { testbed.bridge.session(id: id)?.state.isWorking == true }
            try await testbed.bridge.abort(id)
            try await eventually("又停下") { testbed.bridge.session(id: id)?.state == .settled }
            try await writing.value
            #expect(try #require(testbed.bridge.session(id: id)?.context?.tokens) >= used)

            let after = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply?.contains("AFTER") == true)
        }
    }

    /// 命令比等的时限长：没被打断就等不到这句的回答。
    @Test(arguments: [false, true]) func aMessageWhileBusyStopsTheTurnAndStartsANewOne(toolRunning: Bool) async throws {
        AgentTape.variant(toolRunning ? "tool" : "asking")
        try await ClaudeTestbed.run(settings: toolRunning ? nil : #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let never = testbed.work.appending(path: "never.txt")

            if toolRunning {
                try await testbed.bridge.send(PiMessage(text: "用 Bash 工具在前台执行 `ping -c 110 127.0.0.1 && touch \(never.path)`（不要放后台），然后只回复 ZEBRA"), to: id)
                try await eventually("在跑命令") { testbed.bridge.session(id: id)?.detail?.contains("ping -c 110") == true }
            } else {
                try await testbed.bridge.send(PiMessage(text: "用 Bash 工具执行 touch \(never.path) ，然后只回复 ZEBRA"), to: id)
                _ = try await testbed.waitForQuestion(id)
            }
            let delivery = UUID().uuidString
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 MANGO", deliveryID: delivery), to: id)
            try await testbed.waitForTurn(id, since: asked)
            try await testbed.waitForDraftLanded(id)

            let session = try #require(testbed.bridge.session(id: id))
            #expect(session.state == .settled && session.question == nil)
            #expect(!FileManager.default.fileExists(atPath: never.path))
            let said = try testbed.transcript(session.sessionFile).messages
            let mango = try #require(said.firstIndex { $0.deliveryID == UUID(uuidString: delivery) })
            #expect(said[..<mango].contains { $0.text == PiNotice.stopped.rawValue }, "\(said.map(\.text))")
            #expect(said.last?.text.contains("MANGO") == true, "\(said.map(\.text))")
        }
    }

    @Test func cuePadChangesModelEffortAndNameOfAHostedSession() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let file = try #require(testbed.bridge.session(id: id)?.sessionFile)
            let first = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: first)
            try await testbed.waitForDraftLanded(id)
            #expect(testbed.bridge.session(id: id)?.model?.key.id == claudeTestModel, "\(String(describing: testbed.bridge.session(id: id)?.model))")
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
    @Test func anEndedHostedSessionIsResumedWithItsHistory() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let first = try #require(testbed.bridge.session(id: id))
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "记住暗号 BANANA42，只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)
            try await testbed.bridge.configure(PiConfig(model: other), in: id)
            let writing = Task { try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id) }
            try await eventually("开始这一轮") { testbed.bridge.session(id: id)?.state.isWorking == true }
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
            #expect(testbed.bridge.session(id: resumed)?.model?.key == other, "\(String(describing: testbed.bridge.session(id: resumed)?.model))")
            #expect(testbed.bridge.session(id: resumed)?.firstMessage == "记住暗号 BANANA42，只回复 OK")
            let transcript = try testbed.transcript(first.sessionFile)
            #expect(transcript.recap.lastReply?.contains("BANANA42") == true)
            let file = try #require(first.sessionFile)
            #expect(lastAnswer(in: file)?.model?.contains(claudeOtherModel) == true)
            let replies = transcript.messages.filter { $0.role == .known(.pi) }.map(\.text)
            #expect(!replies.contains("No response requested."), "\(replies)")
        }
    }

    @Test func backgroundWorkKeepsTheSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.backgroundWork), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    @Test func aSubagentThatReportsEarlyAndRunsAgainSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.earlyReport), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "NESTED_DONE", roster: .done, waits: 2)
        }
    }

    @Test func aStoppedSubagentSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.longSubagent), to: id)
            try await eventually("等子代理") { testbed.bridge.session(id: id)?.state == .delegating }
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.stopSubagent), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "STOPPED", roster: .interrupted)
        }
    }

    @Test func anIdleHostedSessionExits() async throws {
        // 空闲计时在 CuePad 这边：回放时不必真等 2 秒
        try await ClaudeTestbed.run(idleLimit: AgentTape.active.mode == .replay ? .milliseconds(50) : .seconds(2)) { testbed in
            try testbed.startConnected()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)

            try await eventually("空闲退出") { log.ended.map(\.0.id) == [id] }
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])
        }
    }
}
#endif

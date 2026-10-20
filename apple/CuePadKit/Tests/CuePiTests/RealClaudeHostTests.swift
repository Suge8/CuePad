#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Claude Code（真 `claude`，stream-json，没有终端界面）——开新会话、带图发话、作答、停止、换模型与强度、改名、
/// 斜杠命令、结束、接着已结束的会话、空闲退出、后台工作交回后才歇下（托管的会话让给终端里打开的那个在 `RealClaudeTerminalTests`）。托管进程自己也跑装好的钩子，桥上不多出一个会话。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.serialWhenRecording(.claudeCode), RealAgents.timeLimit(.minutes(8)))
struct RealClaudeHostTests {
    /// CuePad 起的 `claude` 是外壳、真 claude 是它的子进程：托管进程的钩子仍认得是它自己的，桥上不多出一个终端会话。
    /// 只看提交那一刻的钩子（`UserPromptSubmit` 在调模型之前），不等模型回答。
    @Test func aWrappedClaudeIsNotSeenTwice() async throws {
        try await ClaudeTestbed.run(wrapper: ClaudeTestbed.passThrough) { testbed in
            try testbed.runtime.start()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t-wrapped", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(testbed.bridge.session(id: id)?.sessionID)

            try await testbed.bridge.send(PiMessage(text: "Reply with the single word WRAPPED."), to: id)
            try await eventually("这一轮开始又结束", timeout: .seconds(120)) {
                log.states.contains { $0.isWorking } && testbed.bridge.session(id: id)?.state.isWorking == false
            }
            #expect(log.changes.allSatisfy { if case .appeared(let s) = $0 { s.sessionID != sessionID || s.id == id } else { true } })
        }
    }

    /// 新会话带着发起方的认领标识上桥；发的话带图，会话文件里认得出是哪条投送请求、图存进了附件目录。
    @Test func aNewHostedSessionTakesAMessageWithAnImage() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
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
            #expect(said.text.hasPrefix("不用工具，直接看图：它是红色还是蓝色？只答颜色词\n![](cuepad://img/"))
            #expect(transcript.recap.lastReply?.contains("红") == true, "\(String(describing: transcript.recap.lastReply))")
            #expect(testbed.bridge.sessions.filter { $0.sessionID == session.sessionID }.count == 1)
        }
    }

    /// 托管会话以 auto 模式跑：只读命令与工作目录里的改动不问人；用户的 ask 规则仍要确认，从 CuePad 作答。
    /// 跑着的一轮能停，停了上下文用量不归零，还能接着说。
    @Test func cuePadAnswersAPermissionAndStopsARunningTurn() async throws {
        try await ClaudeTestbed.run(settings: #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.runtime.start()
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
            try await eventually("在跑命令", timeout: .seconds(60)) {
                if let asked = testbed.bridge.session(id: id)?.question?.promptID { try? await testbed.bridge.answer(.confirmed(true), to: asked, in: id) }
                return testbed.bridge.session(id: id)?.state == .tool
            }
            try await testbed.bridge.abort(id)
            try await eventually("停下", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state == .settled }

            // 模型还没回出一个字就停：这一轮的用量全是 0，上下文仍是上一次的
            let used = try #require(testbed.bridge.session(id: id)?.context?.tokens)
            try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id)
            try await eventually("开始这一轮", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state.isWorking == true }
            try await testbed.bridge.abort(id)
            try await eventually("又停下", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state == .settled }
            #expect(try #require(testbed.bridge.session(id: id)?.context?.tokens) >= used)

            let after = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id, since: after)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply?.contains("AFTER") == true)
        }
    }

    /// 在跑时说话：先停下这一轮（连同正等你确认的工具、或前台跑着的命令），再以这句开新一轮；被停下的那一轮不算出错、不算歇下，
    /// 等你确认的问题收起，对话里在这句之前留一行"已停止"。命令比等的时限长：没被打断就等不到这句的回答。
    @Test(arguments: [false, true]) func aMessageWhileBusyStopsTheTurnAndStartsANewOne(toolRunning: Bool) async throws {
        AgentTape.variant(toolRunning ? "tool" : "asking")
        try await ClaudeTestbed.run(settings: toolRunning ? nil : #"{"permissions": {"ask": ["Bash(touch *)"]}}"#) { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let never = testbed.work.appending(path: "never.txt")

            if toolRunning {
                try await testbed.bridge.send(PiMessage(text: "用 Bash 工具在前台执行 `ping -c 110 127.0.0.1 && touch \(never.path)`（不要放后台），然后只回复 ZEBRA"), to: id)
                try await eventually("在跑命令", timeout: .seconds(60)) { testbed.bridge.session(id: id)?.detail?.contains("ping -c 110") == true }
            } else {
                try await testbed.bridge.send(PiMessage(text: "用 Bash 工具执行 touch \(never.path) ，然后只回复 ZEBRA"), to: id)
                _ = try await testbed.waitForQuestion(id)
            }
            let delivery = UUID().uuidString
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 MANGO", deliveryID: delivery), to: id)
            try await testbed.waitForTurn(id, since: asked, timeout: .seconds(60))
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

    /// 换模型与强度、改名（设置与斜杠命令两条路）都改到 Claude Code 自己身上：之后的回答是新模型、新强度答的（看会话文件里它记下的），名字写进了会话文件。
    @Test func cuePadChangesModelEffortAndNameOfAHostedSession() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let file = try #require(testbed.bridge.session(id: id)?.sessionFile)
            let first = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: first)
            try await testbed.waitForDraftLanded(id)
            #expect(testbed.bridge.session(id: id)?.model?.key.id == claudeTestModel, "\(String(describing: testbed.bridge.session(id: id)?.model))")
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)

            try await testbed.bridge.configure(model: other, thinking: .low, name: "托管改名", in: id)
            await #expect(throws: PiBridgeError.unknownModel(.claudeCode)) {
                try await testbed.bridge.configure(model: PiModelKey(provider: ClaudeCode.provider, id: "no-such-model"), in: id)
            }
            try await testbed.bridge.command("/rename 命令改名", in: id)
            try await eventually("斜杠命令改了名、歇下", timeout: .seconds(60)) {
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

    /// 会话文件里最后一条模型回答记下的模型与强度
    private func lastAnswer(in file: URL) -> (model: String?, effort: String?)? {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.reversed().lazy.compactMap { JSONValue.parse(Data($0.utf8)) }.first { $0["type"]?.string == "assistant" }
            .map { ($0["message"]?["model"]?.string, $0["effort"]?.string) }
    }

    /// 结束托管的会话：进程退出、下桥；之后在后台接着它，上一轮说过的它还记得，模型是在 CuePad 里最后选的那个（不回到配置里的）。
    /// 结束前停下的那一轮，Claude Code 接着时补写的助手消息（"No response requested."）不算它的回答。
    @Test func anEndedHostedSessionIsResumedWithItsHistory() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let first = try #require(testbed.bridge.session(id: id))
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "记住暗号 BANANA42，只回复 OK"), to: id)
            try await testbed.waitForTurn(id, since: start)
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)
            try await testbed.bridge.configure(model: other, in: id)
            try await testbed.bridge.send(PiMessage(text: "写一篇两千字的茶叶史"), to: id)
            try await eventually("开始这一轮", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state.isWorking == true }
            try await testbed.bridge.abort(id)
            try await eventually("停下", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state == .settled }
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
            // 接着的会话仍叫它的第一句，不是接着说的这句
            #expect(testbed.bridge.session(id: resumed)?.firstMessage == "记住暗号 BANANA42，只回复 OK")
            let transcript = try testbed.transcript(first.sessionFile)
            #expect(transcript.recap.lastReply?.contains("BANANA42") == true)
            let file = try #require(first.sessionFile)
            #expect(lastAnswer(in: file)?.model?.contains(claudeOtherModel) == true)
            let replies = transcript.messages.filter { $0.role == .known(.pi) }.map(\.text)
            #expect(!replies.contains("No response requested."), "\(replies)")
        }
    }

    /// 后台子代理与后台命令都算在飞：这一轮歇下时是等子代理，交回结果的那一轮做完才歇下一次（叫醒 Cue、提示"完成了"都只这一次）。
    @Test func backgroundWorkKeepsTheSessionBusyUntilItsResultIsReportedBack() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.backgroundWork), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "BG_DONE", roster: .done)
        }
    }

    /// 子代理先交回中途结果、名下的后台命令做完后以同一 id 再跑：中间一直算在飞，交回最终结果的那一轮做完才歇下一次，名册里还是那一项。
    @Test func aSubagentThatReportsEarlyAndRunsAgainSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.earlyReport), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "NESTED_DONE", roster: .done, waits: 2)
        }
    }

    /// 等子代理时你叫它停掉子代理：被停下的不算在飞，这件事只歇下一次，名册里它记成被停下。
    @Test func aStoppedSubagentSettlesTheSessionOnce() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let start = Date()
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.longSubagent), to: id)
            try await eventually("等子代理", timeout: .seconds(120)) { testbed.bridge.session(id: id)?.state == .delegating }
            _ = try await testbed.bridge.send(PiMessage(text: ClaudeTestbed.stopSubagent), to: id)
            try await testbed.expectSettledOnce(id, since: start, reply: "STOPPED", roster: .interrupted)
        }
    }

    /// 托管的会话空闲满时限就退出（不算结束：之后发话再接着它）。
    @Test func anIdleHostedSessionExits() async throws {
        // 空闲计时在 CuePad 这边：回放时不必真等 2 秒
        try await ClaudeTestbed.run(idleLimit: AgentTape.active.mode == .replay ? .milliseconds(50) : .seconds(2)) { testbed in
            try testbed.runtime.start()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)

            try await eventually("空闲退出", timeout: .seconds(60)) { log.ended.map(\.0.id) == [id] }
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])
        }
    }
}
#endif

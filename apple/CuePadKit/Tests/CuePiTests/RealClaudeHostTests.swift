#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Claude Code（真 `claude`，stream-json，没有终端界面）——开新会话、带图发话、作答、停止、换模型与强度、改名、
/// 斜杠命令、结束、接着已结束的会话、空闲退出。托管进程自己也跑装好的钩子，桥上不多出一个会话。
@MainActor
@Suite(.enabled(if: realClaudeAvailable, RealAgents.skipped(.claudeCode, needs: "claude 与 Claude 订阅令牌")), .serialized, .timeLimit(.minutes(8)))
struct RealClaudeHostTests {
    /// CuePad 起的 `claude` 是外壳、真 claude 是它的子进程：托管进程的钩子仍认得是它自己的，桥上不多出一个终端会话。
    /// 只看提交那一刻的钩子（`UserPromptSubmit` 在调模型之前），不等模型回答。
    @Test func aWrappedClaudeIsNotSeenTwice() async throws {
        try await ClaudeTestbed.run(wrapped: true) { testbed in
            try testbed.runtime.start()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t-wrapped", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(testbed.bridge.session(id: id)?.sessionID)

            _ = try await testbed.bridge.send(PiMessage(text: "Reply with the single word WRAPPED."), to: id)
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
            let delivered = try await testbed.bridge.send(PiMessage(text: "图片是什么颜色？只答颜色词", images: [image], deliveryID: delivery), to: id)
            #expect(delivered == .immediate)
            try await testbed.waitForTurn(id)

            let transcript = try testbed.transcript(session.sessionFile)
            let said = try #require(transcript.messages.first { $0.role == .known(.user) })
            #expect(said.deliveryID == UUID(uuidString: delivery))
            #expect(said.text.hasPrefix("图片是什么颜色？只答颜色词\n![](cuepad://img/"))
            #expect(transcript.recap.lastReply?.contains("红") == true)
            #expect(testbed.bridge.sessions.filter { $0.sessionID == session.sessionID }.count == 1)
        }
    }

    /// 等你确认（托管进程问 CuePad 能不能用工具）从 CuePad 作答；跑着的一轮能停，停了还能接着说。
    @Test func cuePadAnswersAPermissionAndStopsARunningTurn() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let touched = testbed.work.appending(path: "hosted.txt")

            _ = try await testbed.bridge.send(PiMessage(text: "用 Bash 工具执行 touch \(touched.path) ，然后只回复 DONE"), to: id)
            let permission = try await testbed.waitForQuestion(id)
            #expect(permission.kind == .known(.confirm))
            try await testbed.bridge.answer(.confirmed(true), to: try #require(permission.promptID), in: id)
            try await testbed.waitForTurn(id)
            #expect(FileManager.default.fileExists(atPath: touched.path))

            _ = try await testbed.bridge.send(PiMessage(text: "用 Bash 工具在前台执行 python3 -c 'import time; time.sleep(120)'（不要放到后台），然后只回复 SLEPT"), to: id)
            // 跑命令也要确认（模型不同，问不问不一定）：问了就允许。不用 sleep：Claude Code 会把它挪到后台
            try await eventually("在跑命令", timeout: .seconds(60)) {
                if let asked = testbed.bridge.session(id: id)?.question?.promptID { try? await testbed.bridge.answer(.confirmed(true), to: asked, in: id) }
                return testbed.bridge.session(id: id)?.state == .tool
            }
            try await testbed.bridge.abort(id)
            try await eventually("停下", timeout: .seconds(30)) { testbed.bridge.session(id: id)?.state == .settled }

            _ = try await testbed.bridge.send(PiMessage(text: "只回复 AFTER"), to: id)
            try await testbed.waitForTurn(id)
            #expect(try testbed.transcript(testbed.bridge.session(id: id)?.sessionFile).recap.lastReply?.contains("AFTER") == true)
        }
    }

    /// 换模型与强度、改名（设置与斜杠命令两条路）都改到 Claude Code 自己身上：之后的回答是新模型、新强度答的（看会话文件里它记下的），名字写进了会话文件。
    @Test func cuePadChangesModelEffortAndNameOfAHostedSession() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let file = try #require(testbed.bridge.session(id: id)?.sessionFile)
            let other = PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel)

            try await testbed.bridge.configure(model: other, thinking: .low, name: "托管改名", in: id)
            await #expect(throws: PiBridgeError.rejected("unknown_model")) {
                try await testbed.bridge.configure(model: PiModelKey(provider: ClaudeCode.provider, id: "no-such-model"), in: id)
            }
            try await testbed.bridge.command("/rename 命令改名", in: id)
            try await eventually("斜杠命令改了名、歇下", timeout: .seconds(60)) {
                testbed.bridge.session(id: id)?.displayName == "命令改名" && testbed.bridge.session(id: id)?.state == .settled
            }
            await #expect(throws: PiBridgeError.rejected("unknown_command")) { try await testbed.bridge.command("/no-such-command", in: id) }

            _ = try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id)
            let answered = try #require(lastAnswer(in: file))
            #expect(answered.model?.contains(claudeOtherModel) == true, "\(String(describing: answered.model))")
            #expect(answered.effort == "low")
            #expect(try testbed.transcript(file).history.name == "命令改名")
        }
    }

    /// 会话文件里最后一条模型回答记下的模型与强度
    private func lastAnswer(in file: URL) -> (model: String?, effort: String?)? {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.reversed().lazy.compactMap { JSONValue.parse(Data($0.utf8)) }.first { $0["type"]?.string == "assistant" }
            .map { ($0["message"]?["model"]?.string, $0["effort"]?.string) }
    }

    /// 结束托管的会话：进程退出、下桥；之后在后台接着它，上一轮说过的它还记得。
    @Test func anEndedHostedSessionIsResumedWithItsHistory() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let first = try #require(testbed.bridge.session(id: id))
            _ = try await testbed.bridge.send(PiMessage(text: "记住暗号 BANANA42，只回复 OK"), to: id)
            try await testbed.waitForTurn(id)
            let log = ChangeLog(testbed.bridge)

            try await testbed.bridge.end(id)
            #expect(testbed.bridge.session(id: id) == nil)
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])

            let indexed = IndexedSession(
                id: first.sessionID, path: first.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
            let resumed = try await testbed.runtime.resume(indexed)
            #expect(testbed.bridge.session(id: resumed)?.sessionID == first.sessionID)
            _ = try await testbed.bridge.send(PiMessage(text: "刚才的暗号是什么？只回复暗号"), to: resumed)
            try await testbed.waitForTurn(resumed)
            #expect(try testbed.transcript(first.sessionFile).recap.lastReply?.contains("BANANA42") == true)
        }
    }

    /// 用户在终端里打开了 CuePad 正托管着的会话：托管的进程让出（空闲就退），桥上换成终端里的那个。
    @Test func aHostedSessionYieldsWhenTheUserOpensItInTheTerminal() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.runtime.start()
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(testbed.bridge.session(id: id)).sessionID
            _ = try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
            try await testbed.waitForTurn(id)
            let log = ChangeLog(testbed.bridge)

            let terminal = try await testbed.terminal(["--resume", sessionID])

            let opened = try await testbed.waitForSession(pid: terminal.pid)
            #expect(opened.sessionID == sessionID && !opened.hosted)
            try await eventually("托管的让出", timeout: .seconds(60)) { log.ended.map(\.0.id) == [id] }
        }
    }

    /// 托管的会话空闲满时限就退出（不算结束：之后发话再接着它）。
    @Test func anIdleHostedSessionExits() async throws {
        try await ClaudeTestbed.run(idleLimit: .seconds(2)) { testbed in
            try testbed.runtime.start()
            let log = ChangeLog(testbed.bridge)
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)

            try await eventually("空闲退出", timeout: .seconds(60)) { log.ended.map(\.0.id) == [id] }
            #expect(log.ended.map(\.1) == [.closed(reason: "quit")])
        }
    }
}
#endif

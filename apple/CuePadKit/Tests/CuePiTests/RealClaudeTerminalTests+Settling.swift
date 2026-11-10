#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// Claude Code 自己歇下了、却不跑 `Stop` 的几条路：会话只能照会话文件里它写下的那一行收尾。
extension RealClaudeTerminalTests {
    /// 主会话歇着、后台子代理在跑时在终端里按 Ctrl-C：Claude Code 停掉子代理、写一行 `agents_killed`，不开一轮，没有 `Stop` 也没有 `SubagentStop`。
    @Test func ctrlCStoppingABackgroundSubagentSettlesTheSession() async throws {
        try await ClaudeTestbed.run(settings: ClaudeTestbed.backgroundSettings) { testbed in
            try testbed.startConnected()
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.playLongSubagent()
            try await terminal.type(ClaudeTestbed.longSubagent)
            // 终端画面比钩子慢：`Stop` 已到、CuePad 已报等子代理时，终端可能还在收这一轮，这时的 Ctrl-C 停的是这一轮、不动子代理。等它画出歇着在等子代理
            try await testbed.waitOnScreen("主会话歇着、子代理在跑命令", on: terminal, in: session.id) {
                let now = testbed.bridge.session(id: session.id), screen = await terminal.screen
                return now?.state == .delegating && now?.subagents.first?.action.contains("time.sleep(60)") == true
                    && screen.contains("Waiting for 1 background agent")
            }
            try await terminal.keys("C-c")
            try await testbed.waitOnScreen("子代理停下、会话歇下", on: terminal, in: session.id) {
                testbed.bridge.session(id: session.id)?.state == .settled
            }
            let now = try #require(testbed.bridge.session(id: session.id))
            #expect(now.subagents.map(\.phase) == [.known(.interrupted)], "\(now.subagents)")
            let turn = try #require(now.turnStartedAt), answered = try #require(try testbed.transcript(now.sessionFile).recap.answeredAt)
            #expect(turn <= answered, "Cue 收得到做完：\(turn) \(answered)")
        }
    }

    /// 你自己的 `UserPromptSubmit` 钩子挡下这句（exit 2）：CuePad 的钩子已开了这一轮，Claude Code 不跑这一轮，也不跑 `Stop`。
    @Test func aPromptBlockedByTheUsersHookSettlesAndCuePadsNextMessageIsTaken() async throws {
        let blocker = #"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "grep -q BLOCKME && { echo blocked-by-user-hook >&2; exit 2; }; exit 0"}]}]}}"#
        try await ClaudeTestbed.run(settings: blocker) { testbed in
            try testbed.startConnected()
            testbed.on("只回复 OK", .say("OK"))
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await terminal.type("BLOCKME 只回复 OK")
            try await testbed.waitOnScreen("挡下后歇下", on: terminal, in: session.id) {
                await terminal.screen.contains("blocked-by-user-hook") && testbed.bridge.session(id: session.id)?.state == .settled
            }
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: session.id)
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "OK")
        }
    }
}
#endif

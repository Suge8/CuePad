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

    /// 挡下的那一行晚于 CuePad 收到这句的钩子写下（你的钩子比 CuePad 的慢），紧接着说一句正常的话：这一轮跑完之前不歇下。
    /// 下一句从 CuePad 发：挡下的那句留在终端的输入框里，在终端里打会接在它后面。
    @Test func theNextPromptAfterABlockedOneRunsUntilItsEnd() async throws {
        let release = FileManager.default.temporaryDirectory.appending(path: "release-\(UUID().uuidString)")
        let settings = #"{"permissions": {"allow": ["Bash"]}, "hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "grep -q BLOCKME && { while [ ! -e '\#(release.path)' ]; do sleep 0.05; done; echo blocked-by-user-hook >&2; exit 2; }; exit 0"}]}]}}"#
        let command = "while [ ! -e finish ]; do sleep 0.05; done; echo RAN"
        try await ClaudeTestbed.run(settings: settings) { testbed in
            try testbed.startConnected()
            testbed.on("RUN-AFTER") { $0.step == 0 ? .call("Bash", ["command": command, "description": "wait"]) : .say("RAN") }
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await terminal.type("BLOCKME 只回复 OK")
            try await eventually("CuePad 收到这句的钩子") { testbed.bridge.session(id: session.id)?.state.isWorking == true }
            try Data().write(to: release)
            try await testbed.waitOnScreen("挡下后歇下", on: terminal, in: session.id) {
                await terminal.screen.contains("blocked-by-user-hook") && testbed.bridge.session(id: session.id)?.state == .settled
            }
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "RUN-AFTER now"), to: session.id)
            try await testbed.waitOnScreen("这一轮在跑命令，CuePad 读过它写下的工具调用", on: terminal, in: session.id) {
                testbed.bridge.session(id: session.id)?.detail?.contains("echo RAN") == true && testbed.hasRead(#""name":"Bash""#, in: session.sessionFile)
            }
            #expect(testbed.bridge.session(id: session.id)?.state.isWorking == true, "命令还在跑：\(String(describing: testbed.bridge.session(id: session.id)?.state))")
            try Data().write(to: testbed.work.appending(path: "finish"))
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "RAN")
        }
    }

    /// 挡下的那一行先被 CuePad 读到、CuePad 才收到这句的钩子（测试台把钩子挂到读过那一行再交给 CuePad）：照样歇下，CuePad 的下一句照常收下。
    @Test func aBlockedPromptReadBeforeItsHookSettles() async throws {
        let blocker = #"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "grep -q BLOCKME && { echo blocked-by-user-hook >&2; exit 2; }; exit 0"}]}]}}"#
        try await ClaudeTestbed.run(settings: blocker) { testbed in
            try testbed.startConnected()
            testbed.on("只回复 OK", .say("OK"))
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            testbed.holdPrompt(containing: "BLOCKME") { testbed.hasRead("promptSubmitEnding", in: session.sessionFile) }
            try await terminal.type("BLOCKME 只回复 OK")
            try await testbed.waitOnScreen("读过挡下的那一行", on: terminal, in: session.id) { testbed.hasRead("promptSubmitEnding", in: session.sessionFile) }
            try await testbed.waitOnScreen("钩子交给 CuePad 之后歇着", on: terminal, in: session.id) {
                let now = testbed.bridge.session(id: session.id)
                return now?.firstMessage?.contains("BLOCKME") == true && now?.state == .settled
            }
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: session.id)
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "OK")
        }
    }

    /// 从头重读会话记录（CuePad 重启、读规则升级）时，读到之前那句被挡下的那一行不算现在的：之后在终端里再交上同一句（挡下的那句留在输入框里，回车即可；这回你的钩子放行）照常开一轮。
    /// CuePad 发的那句带着说明，原话与之不同，测不到这里。
    @Test func aBlockedLineReadAgainFromTheStartDoesNotSwallowTheSamePromptLater() async throws {
        let once = FileManager.default.temporaryDirectory.appending(path: "blocked-once-\(UUID().uuidString)")
        let blocker = #"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "grep -q BLOCKME && [ ! -e '\#(once.path)' ] && { touch '\#(once.path)'; echo blocked-by-user-hook >&2; exit 2; }; exit 0"}]}]}}"#
        try await ClaudeTestbed.run(settings: blocker) { testbed in
            try testbed.startConnected()
            testbed.on("只回复 OK", .say("OK"))
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await terminal.type("BLOCKME 只回复 OK")
            try await testbed.waitOnScreen("挡下后歇下", on: terminal, in: session.id) {
                await terminal.screen.contains("blocked-by-user-hook") && testbed.bridge.session(id: session.id)?.state == .settled
            }
            testbed.rereadFromScratch()
            try await testbed.waitOnScreen("从头重读过挡下的那一行", on: terminal, in: session.id) { testbed.hasRead("promptSubmitEnding", in: session.sessionFile) }
            let start = Date()
            try await terminal.keys("Enter")
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "OK")
        }
    }
    /// 你的 `UserPromptSubmit` 钩子还在查这句时在终端里按 Esc：Claude Code 杀掉钩子、把这句放回输入框，会话记录一行不写，不跑 `Stop`，
    /// 只有登记文件的 `status` 回到 `idle`。会话照它歇下，CuePad 的下一句照常收下。
    @Test func escWhileTheUsersPromptHookRunsSettlesTheSession() async throws {
        let (settings, started, release) = Self.holdingHook()
        defer { try? Data().write(to: release) }
        try await ClaudeTestbed.run(settings: settings) { testbed in
            try testbed.startConnected()
            testbed.on("只回复 OK", .say("OK"))
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            try await terminal.type("HOLDME 只回复 OK")
            try await testbed.waitOnScreen("你的钩子在查这句，CuePad 开了这一轮", on: terminal, in: session.id) {
                FileManager.default.fileExists(atPath: started.path) && testbed.bridge.session(id: session.id)?.state.isWorking == true
            }
            try await terminal.keys("Escape")
            try await testbed.waitOnScreen("按 Esc 后歇下", on: terminal, in: session.id) { testbed.bridge.session(id: session.id)?.state == .settled }
            let start = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: session.id)
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "OK")
        }
    }

    /// CuePad 收到这句的钩子时，登记文件可能还是这句之前的 `idle`（Claude Code 在钩子开跑前写 `busy`，实测只早几毫秒，写盘晚了就倒过来）。
    /// 测试台在你的钩子查这句时把这句之前的登记文件写回去，再让这一轮跑一条命令：命令跑完之前不歇下。
    @Test func aTurnStillShownIdleInTheRegistryRunsUntilItsEnd() async throws {
        let (hooks, started, release) = Self.holdingHook()
        defer { try? Data().write(to: release) }
        let settings = hooks.replacingOccurrences(of: #"{"hooks""#, with: #"{"permissions": {"allow": ["Bash"]}, "hooks""#)
        let command = "while [ ! -e finish ]; do sleep 0.05; done; echo RAN"
        try await ClaudeTestbed.run(settings: settings) { testbed in
            try testbed.startConnected()
            testbed.on("HOLDME") { $0.step == 0 ? .call("Bash", ["command": command, "description": "wait"]) : .say("RAN") }
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let registry = testbed.config.appending(path: "sessions/\(terminal.pid).json")
            var before = Data()
            try await eventually("登记文件写下 idle") {
                before = (try? Data(contentsOf: registry)) ?? Data()
                return JSONValue.parse(before)?["status"]?.string == "idle"
            }
            let start = Date()
            try await terminal.type("HOLDME run")
            try await testbed.waitOnScreen("你的钩子在查这句，CuePad 开了这一轮", on: terminal, in: session.id) {
                FileManager.default.fileExists(atPath: started.path) && testbed.bridge.session(id: session.id)?.state.isWorking == true
            }
            try before.write(to: registry, options: .atomic)
            await quietPeriod(.milliseconds(500))
            #expect(testbed.bridge.session(id: session.id)?.state.isWorking == true, "\(String(describing: testbed.bridge.session(id: session.id)?.state))")
            try Data().write(to: release)
            try await testbed.waitOnScreen("这一轮在跑命令", on: terminal, in: session.id) {
                testbed.bridge.session(id: session.id)?.detail?.contains("echo RAN") == true
            }
            #expect(testbed.bridge.session(id: session.id)?.state.isWorking == true, "命令还在跑：\(String(describing: testbed.bridge.session(id: session.id)?.state))")
            try Data().write(to: testbed.work.appending(path: "finish"))
            try await testbed.waitForTurn(session.id, since: start)
            try await testbed.waitForDraftLanded(session.id)
            #expect(try testbed.transcript(session.sessionFile).recap.lastReply == "RAN")
        }
    }

    /// 你的 `UserPromptSubmit` 钩子对含 HOLDME 的那句开跑时建 `started`，挂到 `release` 出现才放行
    private static func holdingHook() -> (settings: String, started: URL, release: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hold-\(UUID().uuidString)")
        let (started, release) = (directory.appending(path: "started"), directory.appending(path: "release"))
        let command = "grep -q HOLDME && { mkdir -p '\(directory.path)'; touch '\(started.path)'; while [ ! -e '\(release.path)' ]; do sleep 0.05; done; }; exit 0"
        return (#"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\#(command)"}]}]}}"#, started, release)
    }
}
#endif

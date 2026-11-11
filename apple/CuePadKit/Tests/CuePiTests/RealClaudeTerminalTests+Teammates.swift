#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealClaudeTerminalTests {
    /// 进程内队友还在跑时，Claude Code（2.1.318）把那一轮的 `turn_duration` 推迟到队友都停下才写：下一轮里停掉队友，它就落在这一轮中途。
    /// 这一轮的命令还在跑，不算答完。
    @Test func aTurnDurationDeferredForATeammateDoesNotEndTheNextTurn() async throws {
        let settings = #"{"permissions": {"allow": ["Bash", "TaskStop", "Agent"]}, "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}, "teammateMode": "in-process"}"#
        try await ClaudeTestbed.run(settings: settings) { testbed in
            try testbed.startConnected()
            let release = testbed.root.appending(path: "release")
            testbed.on("SPAWN-MATE") { request in
                request.step == 0
                    ? .call("Agent", ["subagent_type": "general-purpose", "name": "mate", "description": "mate", "prompt": "MATE-TASK"]) : .say("SPAWNED")
            }
            testbed.on("MATE-TASK", .say("MATE_DONE"))
            testbed.on("<teammate-message", .say("NOTED"))
            testbed.on("STOP-MATE") { request in
                switch request.step {
                case 0: .call("TaskStop", ["task_id": "mate"])
                case 1: .call("Bash", ["command": "while [ ! -e '\(release.path)' ]; do sleep 0.05; done", "description": "wait"])
                default: .say("STOPPED")
                }
            }
            let terminal = try await testbed.terminal()
            let session = try await testbed.waitForSession(pid: terminal.pid)
            let file = { testbed.bridge.session(id: session.id)?.sessionFile }
            try await terminal.type("SPAWN-MATE now")
            try await eventually("队友歇着、主线程回了它的通知") { (try? testbed.transcript(file()))?.recap.lastReply == "NOTED" }
            let noted = try #require(try testbed.transcript(file()).recap.answeredAt)

            let start = Date()
            try await terminal.type("STOP-MATE now")
            try await eventually("这一轮在跑命令，停掉队友后补写的 turn_duration 落在它前面") {
                guard let text = file().flatMap({ try? String(contentsOf: $0, encoding: .utf8) }), let asked = text.range(of: #""content":"STOP-MATE now""#)
                else { return false }
                let turn = text[asked.upperBound...]
                return turn.contains(#""subtype":"turn_duration""#) && turn.contains(release.path)
            }
            try await eventually("钩子报了这一轮开始") { (testbed.bridge.session(id: session.id)?.turnStartedAt ?? .distantPast) > noted }
            let turn = try #require(testbed.bridge.session(id: session.id)?.turnStartedAt)
            let answered = try testbed.transcript(file()).recap.answeredAt
            #expect(answered.map { $0 < turn } ?? true, "命令还在跑就记成答完：收尾 \(String(describing: answered))，这一轮开始 \(turn)")

            try Data().write(to: release)
            try await testbed.waitForTurn(session.id, since: start)
            try await eventually("这一轮的回答落盘") { (try? testbed.transcript(file()))?.recap.lastReply == "STOPPED" }
        }
    }
}
#endif

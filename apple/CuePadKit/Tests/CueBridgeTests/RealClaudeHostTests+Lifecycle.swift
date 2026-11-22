#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CueBridge

extension RealClaudeHostTests {
    @Test(arguments: ["stop", "end"])
    func stoppingBeforeTheTurnsInitArrivesDoesNotWaitForIt(_ action: String) async throws {
        let withoutInit = #""$REAL" "$@" | /usr/bin/python3 -I -u -c 'import sys"# + "\n"
            + #"for line in sys.stdin: "\"subtype\":\"init\"" in line or print(line, end="", flush=True)'"#
        try await ClaudeTestbed.run(wrapper: withoutInit, timing: .system) { testbed in
            try testbed.startConnected()
            let gate = testbed.model.gate()
            testbed.on("BUSY-HANG", .held(gate, then: .say("LATE")))
            let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
            let session = try #require(testbed.bridge.session(id: id))
            // 这句话收下（`command_lifecycle` 的 completed）要等这一轮做完，所以另起；问到模型时它早发过 init 了
            let sending = Task { try await testbed.bridge.send(SessionMessage(text: "BUSY-HANG keep going"), to: id) }
            try await gate.reached()
            let began = ContinuousClock.now
            if action == "stop" {
                try await testbed.bridge.abort(id)
                #expect(testbed.bridge.session(id: id)?.state == .settled)
            } else {
                try await testbed.bridge.end(id)
                try await eventually("进程收掉") { kill(session.pid, 0) != 0 }
            }
            let took = began.duration(to: .now)
            #expect(took < .seconds(10), "用了 \(took)")
            gate.openForever()
            _ = await sending.result
        }
    }

    @Test func aResumeCancelledBeforeItConnectsLeavesNoProcessBehind() async throws {
        let wrapper = listing + #"dir=${0%/*}; echo $$ >> "$dir/launched"; while [ -e "$dir/slow" ]; do sleep 0.01; done; exec "$REAL" "$@""#
        try await ClaudeTestbed.run(wrapper: wrapper) { testbed in
            try testbed.startConnected()
            let (id, indexed) = try await openWithATurn(testbed)
            try await testbed.bridge.end(id)
            let launched = testbed.wrapperDirectory.appending(path: "launched")
            let pids = { ((try? String(contentsOf: launched, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) } }
            try await eventually("结束的进程退了") { kill(pids()[0], 0) != 0 }

            try Data().write(to: testbed.wrapperDirectory.appending(path: "slow"))
            let cancelled = Task { try await testbed.runtime.resume(indexed) }
            try await eventually("进程起了") { pids().count == 2 }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            try FileManager.default.removeItem(at: testbed.wrapperDirectory.appending(path: "slow"))
            try await eventually("被取消的那次起的进程收掉") { kill(pids()[1], 0) != 0 }

            let resumed = try await testbed.connect(indexed)
            #expect(pids().count == 3)
            #expect(pids().filter { kill($0, 0) == 0 } == [pids()[2]])
            let asked = Date()
            try await testbed.bridge.send(SessionMessage(text: "只回复 OK"), to: resumed)
            try await testbed.waitForTurn(resumed, since: asked)
        }
    }

    private var listing: String { #"[ "$1" = agents ] && exec "$REAL" "$@"; "# }

    private func openWithATurn(_ testbed: ClaudeTestbed) async throws -> (Session.ID, IndexedSession) {
        testbed.on("只回复 OK", .say("OK"))
        let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
        let session = try #require(testbed.bridge.session(id: id))
        let start = Date()
        try await testbed.bridge.send(SessionMessage(text: "只回复 OK"), to: id)
        try await testbed.waitForTurn(id, since: start)
        let indexed = IndexedSession(
            id: session.sessionID, path: session.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
        return (id, indexed)
    }
}

#endif

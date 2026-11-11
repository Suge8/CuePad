#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 托管会话的进程收尾：一个会话同一时刻只有一个 Claude Code 进程写它的会话文件。请它退出、接着它的各家同一组用例在 `RealHostedEndTests`。
/// 外壳（`wrapper`）拉开真 Claude Code 自己太短、碰不到的那一段：起得慢。
extension RealClaudeHostTests {
    /// 这一轮的 `system/init` 还没到 CuePad 时点停止或结束：不等 init，当场停下这一轮（#81：原先等满 `AgentTimeouts.stop`）。
    /// 外壳滤掉 init 那一行，拉长"还没收到 init"这一段。
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

    /// 接着会话时还没连上就被取消（投送到了截止时刻）：自己起的进程收掉、不再占着这个会话；再接着同一会话只起一个进程，照常说话。
    /// 外壳带着 `slow` 标记时停住、不起 Claude Code，直到标记去掉（或被收掉）：进程起了、还没连上。
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
            // 被取消的调用方当场走（`Resumptions`），这次恢复随后收掉自己起的进程；下一次恢复等它收完才起。
            // 停住的外壳不理关输入，放它起真 Claude Code，读到关了的输入就退（runtime 的钟不走，等不到强杀）
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

    /// 接着会话前问 Claude Code 在跑哪些会话（`claude agents --json`）也经外壳：原样跑
    private var listing: String { #"[ "$1" = agents ] && exec "$REAL" "$@"; "# }

    /// 开一个托管会话、说一轮（会话文件有了才接得着）。
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

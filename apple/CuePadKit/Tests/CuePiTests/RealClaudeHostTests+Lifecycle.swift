#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 托管会话的进程收尾：一个会话同一时刻只有一个 Claude Code 进程写它的会话文件，请它退出、接着它都不卡住下一句话。
/// 外壳（`wrapper`）拉开真 Claude Code 自己太短、碰不到的那一段：退得慢、不肯退、起得慢。
extension RealClaudeHostTests {
    /// 歇满空闲时限、被请退出的那一刻就不在桥上：下一句话（`MacExecutor` 的接法）接着它，不撞上正在退出的进程。
    /// 外壳在 Claude Code 读到 EOF 退出后（`eof`：CuePad 已请它退出）还握着输出 3 秒：请它退出了、进程还没走。
    @Test func aMessageRightAfterAnIdleExitResumesTheSession() async throws {
        let wrapper = listing + #""$REAL" "$@"; status=$?; : > "${0%/*}/eof"; sleep 3; exit $status"#
        try await ClaudeTestbed.run(idleLimit: .seconds(3), wrapper: wrapper) { testbed in
            try testbed.startConnected()
            let (id, indexed) = try await openWithATurn(testbed)

            try await eventually("空闲到点，请它退出了") { testbed.hasFile("eof") }
            #expect(testbed.bridge.session(id: id) == nil, "请它退出了还在桥上")
            let resumed = try await testbed.connect(indexed)
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: resumed)
            try await testbed.waitForTurn(resumed, since: asked)
            #expect(resumed != id)
        }
    }

    /// 被请退出后进程不走（外壳不理 SIGTERM、一直握着输出）：宽限后 SIGTERM、再宽限后 SIGKILL 收掉，宽限按 runtime 的钟量；
    /// 下一句话等这次收尾完再起新进程，旧进程在新进程起来之前已经不在。
    /// 外壳带着 `stubborn` 标记起的才这样（接着它起的新进程照常）。
    @Test func anIdleSessionWhoseProcessWontExitIsKilledBeforeItIsResumed() async throws {
        let clock = ManualTiming()
        let wrapper = listing + #"dir=${0%/*}; [ -e "$dir/stubborn" ] || exec "$REAL" "$@"; trap '' TERM; "$REAL" "$@"; : > "$dir/eof"; exec sleep 600"#
        try await ClaudeTestbed.run(idleLimit: .seconds(3), wrapper: wrapper, timing: clock.timing) { testbed in
            try testbed.startConnected()
            try Data().write(to: testbed.wrapperDirectory.appending(path: "stubborn"))
            let (id, indexed) = try await openWithATurn(testbed)
            let old = try #require(testbed.bridge.session(id: id)?.pid)
            try FileManager.default.removeItem(at: testbed.wrapperDirectory.appending(path: "stubborn"))

            try await eventually("空闲到点，请它退出了") { testbed.hasFile("eof") }
            try #require(testbed.bridge.session(id: id) == nil, "请它退出了还在桥上")
            let resuming = Task { try await testbed.connect(indexed) }
            for _ in 0..<2 {
                let due = clock.now.addingTimeInterval(AgentTimeouts.endGrace.seconds)
                try await eventually("在等宽限") { kill(old, 0) != 0 || clock.hasSleeper(until: due) }
                clock.advance(AgentTimeouts.endGrace)
            }
            let resumed = try await resuming.value
            #expect(kill(old, 0) != 0, "旧进程还在")
            #expect(testbed.bridge.session(id: resumed)?.pid != old)
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: resumed)
            try await testbed.waitForTurn(resumed, since: asked)
        }
    }

    /// 接着会话时还没连上就被取消（投送到了截止时刻）：自己起的进程收掉、不再占着这个会话；再接着同一会话只起一个进程，照常说话。
    /// 外壳带着 `slow` 标记时晚 2 秒才起 Claude Code：进程起了、还没连上。
    @Test func aResumeCancelledBeforeItConnectsLeavesNoProcessBehind() async throws {
        let wrapper = listing + #"dir=${0%/*}; echo $$ >> "$dir/launched"; [ -e "$dir/slow" ] && sleep 2; exec "$REAL" "$@""#
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
            #expect(kill(pids()[1], 0) != 0, "被取消的那次起的进程还在")

            try FileManager.default.removeItem(at: testbed.wrapperDirectory.appending(path: "slow"))
            let resumed = try await testbed.connect(indexed)
            #expect(pids().count == 3)
            #expect(pids().filter { kill($0, 0) == 0 } == [pids()[2]])
            let asked = Date()
            try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: resumed)
            try await testbed.waitForTurn(resumed, since: asked)
        }
    }

    /// 接着会话前问 Claude Code 在跑哪些会话（`claude agents --json`）也经外壳：原样跑
    private var listing: String { #"[ "$1" = agents ] && exec "$REAL" "$@"; "# }

    /// 开一个托管会话、说一轮（会话文件有了才接得着）。
    private func openWithATurn(_ testbed: ClaudeTestbed) async throws -> (PiSession.ID, IndexedSession) {
        testbed.on("只回复 OK", .say("OK"))
        let id = try await testbed.runtime.open(in: testbed.work, launchToken: "t", name: nil, model: nil, thinking: nil)
        let session = try #require(testbed.bridge.session(id: id))
        let start = Date()
        try await testbed.bridge.send(PiMessage(text: "只回复 OK"), to: id)
        try await testbed.waitForTurn(id, since: start)
        let indexed = IndexedSession(
            id: session.sessionID, path: session.sessionFile!.path, cwd: testbed.work.path, lastActivityAt: .now, agent: .claudeCode)
        return (id, indexed)
    }
}

private extension ClaudeTestbed {
    /// 外壳在 `wrapperDirectory` 里留下的标记
    func hasFile(_ name: String) -> Bool { FileManager.default.fileExists(atPath: wrapperDirectory.appending(path: name).path) }
}
#endif

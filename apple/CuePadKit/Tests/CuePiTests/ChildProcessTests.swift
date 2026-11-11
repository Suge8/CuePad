#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

struct ChildProcessTests {
    /// 管道缓冲 64 KB：子进程写不进去就卡住，必须在它运行期间就读。
    @Test func outputLargerThanThePipeBufferIsReadInFull() async {
        let result = await ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", "head -c 300000 /dev/zero | tr '\\0' x; exit 3"])
        #expect(result?.status == 3 && result?.output.count == 300_000)
    }

    /// 卡住的进程（连 SIGTERM 也不理）到时间就结束它、不等下去；取消调用方不撤掉超时，也不拿取消当退出码。
    /// 超时用手动钟量：命令真起来之后才推进，到点由测试定，不和机器忙不忙赛跑。
    @Test func aStuckProcessIsStoppedAtTheTimeoutEvenWhenTheCallerIsCancelled() async throws {
        let started = try makeTempDirectory().appending(path: "started")
        let clock = ManualTiming()
        let call = Task { await ChildProcess.attempt(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; touch '\(started.path)'; sleep 30"], timeout: .seconds(1), timing: clock.timing) }
        try await eventually("命令跑起来了") { !fileGone(started) }
        call.cancel()
        try await clock.waitForSleeper()
        clock.advance(.seconds(1))
        guard case .timedOut = await call.value else { Issue.record("没按超时结束"); return }
        // 它不理 SIGTERM：结束时的宽限也按这个钟，推过去才 SIGKILL，不留下它
        try await clock.waitForSleeper()
        clock.advance(AgentTimeouts.endGrace)
    }

    /// 组长（外壳）收到 SIGTERM 先走了，组里不理 SIGTERM 的子进程也照样有宽限，推过宽限才 SIGKILL。
    @Test func aTimeoutEndsTheChildrenHoldingTheOutputToo() async throws {
        let marker = try makeTempDirectory().appending(path: "child.pid")
        let script = "sh -c \"trap '' TERM; echo \\$\\$ > '\(marker.path)'; sleep 30\" & wait"
        let clock = ManualTiming()
        let call = Task { await ChildProcess.attempt(URL(filePath: "/bin/sh"), ["-c", script], timeout: .seconds(1), timing: clock.timing) }
        try await eventually("子进程写下了 pid") { !fileGone(marker) && ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").hasSuffix("\n") }
        try await clock.waitForSleeper()
        clock.advance(.seconds(1))
        guard case .timedOut = await call.value else { Issue.record("没按超时结束"); return }
        let child = try #require(pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await clock.waitForSleeper()
        #expect(kill(child, 0) == 0, "宽限之前就被强杀了")
        clock.advance(AgentTimeouts.endGrace)
        try await eventually("子进程也结束了") { kill(child, 0) != 0 }
    }

    /// 子进程（与它再起的进程）按默认处置收信号：本进程忽略或屏蔽了的信号不带过去，
    /// 否则 Claude Code 收到结束信号不走、只能 SIGKILL，收件箱 socket 就留在 /tmp/cc-socks。
    @Test func aChildEndsOnSIGTERMEvenIfThisProcessIgnoresIt() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        let child = try await ChildProcess(URL(filePath: "/bin/sleep"), ["30"], placement: .group)
        signal(SIGTERM, previous)

        kill(child.pid, SIGTERM)
        #expect(await child.exited(within: nil))
        child.end()
    }

    /// 不然起到一半 App 就没了、扩展又没接手的 Pi 会一直空转（10-21 测量实例留下的 25 个孤儿）。认领之后照常活着由 `RealHostTests.aHostedSessionOutlivesCuePadAndIsSeenAgainByTheNextOne` 证明。
    @Test func aDetachedProcessNobodyClaimedEndsWithItsLauncher() async throws {
        let started = try makeTempDirectory().appending(path: "started")
        var child: ChildProcess? = try await ChildProcess(
            URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; touch '\(started.path)'; exec sleep 300"], placement: .detached, input: .lifeline)
        let pid = try #require(child?.pid)
        defer { kill(pid, SIGKILL) }  // 见红时别留下
        try await eventually("它跑起来了、不理 SIGTERM") { !fileGone(started) }
        child = nil
        try await eventually("没认领的进程随起它的一方结束") { kill(pid, 0) != 0 }
    }
}
#endif
